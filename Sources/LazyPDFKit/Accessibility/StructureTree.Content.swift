import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/StructureTree.Content.cs: edits of the page content that go with the tree.
// `markAsArtifact` and the tag functions throw only the `ArgumentException` of `add`, which the checks before it rule out.

/// Why an edit of the page content was refused; `AccessibilityText.contentReason` gives the message. The keys of `TagRules` can come back from `tagSelection` too.
public enum TagContent {
    public static let truncated = "truncated"
    public static let notInTree = "not-in-tree"
    public static let notContent = "not-content"
    public static let formContent = "form-content"
    public static let sharedStream = "shared-stream"
    public static let unreadable = "unreadable-content"
    public static let nestedTagged = "nested-tagged"
    public static let partialMarked = "partial-marked"
    public static let splitOperation = "split-operation"
    public static let emptySelection = "empty-selection"
    public static let tooLarge = "too-large"
}

/// The element a selection was tagged as, or why nothing changed.
public struct TagSelectionResult {
    public let element: StructElement?
    public let reason: String?
}

extension StructureTree {
    private static let artifactKeys = ["Type", "BBox", "Attached", "Subtype"]

    /// Turns the marked content of `kid` (a sequence, or an element with everything under it) into /Artifact in the page's
    /// content and takes it out of the tree; elements left without kids go too, but never a root. The content draws the
    /// same: an /MCID sequence becomes BMC /Artifact, or BDC /Artifact keeping its type, box, attached and subtype
    /// entries. Nil when done, otherwise the reason and nothing is changed: content in a form XObject or in a stream
    /// another page draws, tagged content nested in the sequence or around it, or content that does not parse. Call
    /// `write` afterwards. An object reference is not content.
    public func markAsArtifact(_ kid: StructKid) -> String? {
        if isTruncated { return TagContent.truncated }
        if kid is StructObject { return TagContent.notContent }
        if indexIn(kid) < 0 { return TagContent.notInTree }
        let contents: [StructContent]
        if let element = kid as? StructElement {
            contents = Self.subtree(element).flatMap { $0.kidList.compactMap { $0 as? StructContent } }
        } else {
            contents = [kid as! StructContent]
        }
        if contents.contains(where: { $0.stream != nil }) { return TagContent.formContent }

        var plans: [(page: PageStreams, edits: [[ContentInsertion]])] = []
        let pages = document.pages
        var byPage: [Int: [StructContent]] = [:]
        for c in contents where c.pageIndex >= 0 && c.pageIndex < pages.count { byPage[c.pageIndex, default: []].append(c) }
        for pageIndex in byPage.keys.sorted() {
            guard let page = PageStreams.load(document, pages[pageIndex]) else { return TagContent.unreadable }
            if page.isShared { return TagContent.sharedStream }
            let ids = Set(byPage[pageIndex]!.map { $0.mcid })
            var edits = page.newEdits()
            let properties = page.properties()
            let top = MarkedSequence.scan(page, document)
            for sequence in top.descendants() {
                guard let id = sequence.mcid, ids.contains(id) else { continue }
                var around = false
                var p = sequence.parent
                while let up = p, up.begin >= 0 {
                    if let outer = up.mcid, !ids.contains(outer) { around = true }
                    p = up.parent
                }
                if around || sequence.descendants().contains(where: { d in d.mcid.map { !ids.contains($0) } ?? false }) { return TagContent.nestedTagged }
                let (stream, op) = page.at(sequence.begin)
                edits[stream].append(ContentInsertion(position: op.start, order: 1, text: Self.artifactOpening(op, properties), skip: op.end - op.start))
            }
            plans.append((page, edits))
        }
        for plan in plans { plan.page.save(plan.edits) }

        let parent = kid.parent
        remove(kid)
        dropEmpty(parent)
        return nil
    }

    private static func artifactOpening(_ op: ContentOperation, _ properties: (String) -> PdfDictionary?) -> String {
        var dictionary: PdfDictionary?
        if op.operands.count > 1 {
            if let d = op.operands[1] as? PdfDictionary {
                dictionary = d
            } else if let n = op.operands[1] as? PdfName {
                dictionary = properties(n.value)
            }
        }
        let kept = PdfDictionary()
        for key in artifactKeys {
            if let value = dictionary?[key], !(value is PdfReference) { kept[key] = value }
        }
        return kept.count > 0 ? "/Artifact \(kept) BDC" : "/Artifact BMC"
    }

    /// Tags the characters of `ranges` (indexes into `TextPage.chars` of `TextPage.create(document, page)`, as the viewer's
    /// selection gives them) as a new element of `type`; see `tagArea` for the rules.
    public func tagSelection(_ pageIndex: Int, _ ranges: [TextRange], _ type: String, _ parent: StructElement?, _ index: Int = -1) throws -> TagSelectionResult {
        try tagContent(pageIndex, ranges, nil, type, parent, index)
    }

    /// Tags what lies inside `area` (page user space): the characters whose centers are in it and the pictures and forms
    /// that are wholly in it. The content gets /MCID sequences, the new element goes under `parent` at `index` (-1 for the
    /// end, counted after the content left its old place) and a tree with no root gets a Document one. Content that
    /// already has an /MCID in the tree moves to the new element when the whole sequence is picked; a sequence marked
    /// /Artifact or with an /MCID the tree does not name takes a new number the same way; anything else already marked is
    /// refused. A string cut by the selection, a partly covered sequence, content in a form XObject or a shared stream are
    /// refused with nothing changed (a reason of `TagContent` or `TagRules`). Call `write` afterwards.
    public func tagArea(_ pageIndex: Int, _ area: PdfRect, _ type: String, _ parent: StructElement?, _ index: Int = -1) throws -> TagSelectionResult {
        try tagContent(pageIndex, nil, area, type, parent, index)
    }

    private func tagContent(_ pageIndex: Int, _ ranges: [TextRange]?, _ area: PdfRect?, _ type: String, _ givenParent: StructElement?, _ index: Int) throws -> TagSelectionResult {
        func refused(_ reason: String) -> TagSelectionResult { TagSelectionResult(element: nil, reason: reason) }
        if isTruncated { return refused(TagContent.truncated) }
        let pages = document.pages
        if pageIndex < 0 || pageIndex >= pages.count { return refused(TagContent.notInTree) }
        let element = StructElement(type)
        element.pageIndex = pageIndex
        guard let standard = resolveNew(element, type, nil) else { return refused(TagRules.unmapped) }
        var parent = givenParent
        if let parent, indexIn(parent) < 0 { return refused(TagContent.notInTree) }
        let makeRoot = parent == nil && rootList.isEmpty
        let parentType = makeRoot ? "Document" : parent.map { standardType($0.type) } ?? ""
        if let placement = TagRules.canPlace(parentType, standard) { return refused(placement) }
        if TagRules.hasFixedKids(standard) { return refused(TagRules.noContent) }
        if standard == "Link" { return refused(TagRules.linkObject) }

        guard let page = PageStreams.load(document, pages[pageIndex]) else { return refused(TagContent.unreadable) }
        if page.isShared { return refused(TagContent.sharedStream) }
        let picked = pick(page, TextPage.create(document, pages[pageIndex]), ranges, area)
        if let why = picked.reason { return refused(why) }
        let selected = picked.selected

        // Loose operations get a new sequence; a marked sequence the selection holds whole is claimed; one it holds in part is refused.
        var claims: [Int: TagNode] = [:]
        var claimed: [MarkedSequence] = []
        let node = TagNode(type)
        func whole(_ s: MarkedSequence) -> Bool {
            let all = s.allContent()
            return all.contains { selected.contains($0) } && all.allSatisfy { selected.contains($0) || !picked.required($0) }
        }
        func walk(_ sequence: MarkedSequence, _ inClaimed: Bool) -> Bool {
            for child in sequence.children {
                if child.isClaimed && whole(child) {
                    claimed.append(child)
                } else if !walk(child, inClaimed || sequence.isClaimed) {
                    return false
                }
            }
            for op in sequence.content where selected.contains(op) {
                if inClaimed || sequence.isClaimed { return false }
                claims[op] = node
            }
            return true
        }
        let top = MarkedSequence.scan(page, document)
        if !walk(top, false) { return refused(TagContent.partialMarked) }
        if claims.isEmpty && claimed.isEmpty { return refused(TagContent.emptySelection) }

        var named: [Int: StructContent] = [:]
        for c in contents where c.pageIndex == pageIndex && c.stream == nil && named[c.mcid] == nil { named[c.mcid] = c }
        var used = ContentTagger.usedMcids(page.parsed, page.properties(), document)
        used.formUnion(named.keys)
        var next = 0
        func fresh() -> Int {
            while used.contains(next) { next += 1 }
            next += 1
            return next - 1
        }
        let planner = ContentTagger(page.parsed, claims, { _ in fresh() }, artifacts: false)
        planner.run()

        var edits = page.newEdits()
        for s in 0..<edits.count { edits[s].append(contentsOf: planner.insertions[s]) }
        var order: [(stream: Int, position: Int, content: StructContent)] = planner.sequences.map { ($0.stream, $0.position, StructContent(pageIndex, $0.mcid)) }
        var moved: [StructContent] = []
        for sequence in claimed {
            let (stream, op) = page.at(sequence.begin)
            if let id = sequence.mcid, let existing = named[id] {
                moved.append(existing)
                order.append((stream, op.start, existing))
                continue
            }
            let number = fresh()
            edits[stream].append(ContentInsertion(position: op.start, order: 1, text: "\(PdfName(type)) <</MCID \(number)>> BDC", skip: op.end - op.start))
            order.append((stream, op.start, StructContent(pageIndex, number)))
        }
        if order.isEmpty { return refused(TagContent.emptySelection) }
        let highest = order.map { $0.content.mcid }.max() ?? -1
        if highest > Self.maxMcid || parentSlots() + highest + 1 > Self.maxParentSlots { return refused(TagContent.tooLarge) }

        page.save(edits)
        var oldParents: [StructElement] = []
        for c in moved {
            if let old = c.parent, !oldParents.contains(where: { $0 === old }) { oldParents.append(old) }
        }
        for c in moved { remove(c) }
        if makeRoot {
            let root = StructElement("Document")
            try add(nil, root)
            parent = root
        }
        try add(parent, element, index)
        for item in order.sorted(by: { ($0.stream, $0.position) < ($1.stream, $1.position) }) { try add(element, item.content) }
        for old in oldParents { dropEmpty(old) }
        return TagSelectionResult(element: element, reason: nil)
    }

    // The content operations the selection holds in full, and which operations a sequence needs picked to be held whole: a show
    // operation that has no characters (hidden text) is not one of them.
    private func pick(_ page: PageStreams, _ text: TextPage, _ ranges: [TextRange]?, _ area: PdfRect?)
        -> (selected: Set<Int>, required: (Int) -> Bool, reason: String?) {
        var total: [Int: Int] = [:]
        var count: [Int: Int] = [:]
        let chars = text.chars
        for c in chars where c.operatorIndex >= 0 && c.form == nil { total[c.operatorIndex, default: 0] += 1 }
        let required: (Int) -> Bool = { op in
            let name = page.at(op).operation.operator
            return name == "Do" || name == "BI" || total[op] != nil
        }
        var selected = Set<Int>()
        if let ranges {
            var seen = Set<Int>()
            for range in ranges {
                var i = Swift.max(0, range.start)
                while i < Swift.min(range.end, chars.count) {
                    let c = chars[i]
                    if c.operatorIndex >= 0 && seen.insert(i).inserted {
                        if c.form != nil { return ([], required, TagContent.formContent) }
                        count[c.operatorIndex, default: 0] += 1
                    }
                    i += 1
                }
            }
        } else if let area {
            for c in chars {
                let (x, y) = c.quad.center
                if c.operatorIndex >= 0 && c.form == nil && x >= area.left && x <= area.right && y >= area.bottom && y <= area.top {
                    count[c.operatorIndex, default: 0] += 1
                }
            }
            let drawn = Drawn()
            let interpreter = ContentInterpreter(document)
            interpreter.walkPatterns = false
            interpreter.run(page.page, drawn)
            for item in drawn.items {
                let b = item.bounds
                if b.left >= area.left - 1 && b.right <= area.right + 1 && b.bottom >= area.bottom - 1 && b.top <= area.top + 1 {
                    selected.insert(item.operation)
                } else if item.inline && !b.intersect(area).isEmpty {
                    return ([], required, TagContent.splitOperation)
                }
            }
        }
        for (op, n) in count {
            if n < (total[op] ?? 0) { return ([], required, TagContent.splitOperation) }
            selected.insert(op)
        }
        return (selected, required, selected.isEmpty ? TagContent.emptySelection : nil)
    }

    // The pictures and forms the page's own content draws, with where they are.
    private final class Drawn: ContentVisitor {
        var items: [(operation: Int, bounds: PdfRect, inline: Bool)] = []

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            if context.forms.isEmpty { items.append((context.operatorIndex, image.bounds, image.inline != nil)) }
        }

        override func beginForm(_ context: ContentContext, _ form: FormInfo) {
            if !form.isPattern && context.forms.count == 1 { items.append((context.operatorIndex, form.bounds, false)) }
        }
    }

    static func subtree(_ element: StructElement) -> [StructElement] {
        var found: [StructElement] = []
        var stack = [element]
        while let e = stack.popLast() {
            found.append(e)
            stack.append(contentsOf: e.children.reversed())
        }
        return found
    }

    private func dropEmpty(_ start: StructElement?) {
        var e = start
        while let current = e, let parent = current.parent, current.kidList.isEmpty {
            remove(current)
            e = parent
        }
    }
}
