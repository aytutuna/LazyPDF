import Foundation

// Twin of windows/LazyPDF.Core/Editing/EditBatch.cs: the changes of one edit, gathered and then written to the document
// together: cuts in content streams, new resources, content added at the end of the page. A form XObject that something
// else also uses is copied and only the `Do` that was edited is pointed at the copy; one that nothing else uses is
// edited in place. Content streams of the page are rewritten one by one, so a stream the edit does not touch stays the
// object it was.

/// A change that cannot be made as asked, found before anything was written.
struct EditConflictException: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// A content stream and the run of it an edit is about.
struct Place {
    let unit: ContentUnit
    let visit: FormVisit?

    init(_ unit: ContentUnit, _ visit: FormVisit?) {
        self.unit = unit
        self.visit = visit
    }

    /// The scan of this run: a form painted twice starts from the state of each `Do`.
    var states: OpStates { visit?.states ?? unit.states }
}

final class EditBatch {
    private let document: PdfDocument
    private let page: PdfPage
    private let scan: EditScan
    private let firstObject: Int

    init(_ document: PdfDocument, _ page: PdfPage, _ scan: EditScan) {
        self.document = document
        self.page = page
        self.scan = scan
        firstObject = document.nextObjectNumber
    }

    private final class UnitEdit {
        let unit: ContentUnit
        let visit: FormVisit?
        var patches: [Int: ShowPatch] = [:]
        var splices: [Splice] = []
        var resources: [Resource] = []

        init(_ unit: ContentUnit, _ visit: FormVisit?) {
            self.unit = unit
            self.visit = visit
        }

        var depth: Int { visit?.chain.count ?? 0 }
    }

    private struct Resource {
        let category: String
        let name: String
        let value: () -> PdfObject
    }

    private struct PagePlan {
        let parts: [Part]
        let splices: [Splice]
        let groups: [(lo: Int, hi: Int)]
    }

    private final class Work {
        let edit: UnitEdit
        let data: [UInt8]
        let copy: Bool
        var reference: PdfReference?
        var plan: PagePlan?

        init(_ edit: UnitEdit, _ data: [UInt8], _ copy: Bool) {
            self.edit = edit
            self.data = data
            self.copy = copy
        }
    }

    // Kept in the order the units were first edited, which is the order the C# dictionary lists them in.
    private var edits: [ContentUnit: UnitEdit] = [:]
    private var order: [ContentUnit] = []
    private var appended: [[UInt8]] = []
    private var names: Set<String>?
    private var references: [Int: Int]?

    var isEmpty: Bool { edits.isEmpty && appended.isEmpty }

    /// Where the batch stands, to take back what a failed step added.
    struct Mark {
        fileprivate var units: [ContentUnit: (splices: Int, resources: Int, patches: [Int: (cuts: Int, inserts: Int)])] = [:]
        fileprivate var appended = 0
        fileprivate var objects = 0
    }

    func save() -> Mark {
        var mark = Mark()
        mark.appended = appended.count
        mark.objects = document.nextObjectNumber
        for (unit, edit) in edits {
            mark.units[unit] = (edit.splices.count, edit.resources.count, edit.patches.mapValues { $0.count })
        }
        return mark
    }

    func restore(_ mark: Mark) {
        for unit in order where mark.units[unit] == nil { edits[unit] = nil }
        order.removeAll { edits[$0] == nil }
        for (unit, saved) in mark.units {
            guard let edit = edits[unit] else { continue }
            if edit.splices.count > saved.splices { edit.splices.removeSubrange(saved.splices...) }
            if edit.resources.count > saved.resources { edit.resources.removeSubrange(saved.resources...) }
            for op in edit.patches.keys where saved.patches[op] == nil { edit.patches[op] = nil }
            for (op, count) in saved.patches { edit.patches[op]?.truncate(count) }
        }
        if appended.count > mark.appended { appended.removeSubrange(mark.appended...) }
        deleteObjects(mark.objects)
    }

    /// Takes back everything the batch added to the document, for an edit that is given up.
    func discard() { deleteObjects(firstObject) }

    // Fonts and pictures are made in the document as soon as an edit asks for them; an edit taken back must not leave them to be saved.
    private func deleteObjects(_ from: Int) {
        var number = from
        while number < document.nextObjectNumber {
            document.delete(number)
            number += 1
        }
    }

    /// Whether a resource called `name` is still waiting to be written to the stream of `place`.
    func hasResource(_ place: Place, _ name: String) -> Bool {
        edits[place.unit]?.resources.contains { $0.name == name } ?? false
    }

    private func edit(_ place: Place) -> UnitEdit? {
        if let existing = edits[place.unit] {
            if place.unit.visits > 1 && existing.visit !== place.visit { return nil }
            return existing
        }
        let created = UnitEdit(place.unit, place.visit)
        edits[place.unit] = created
        order.append(place.unit)
        return created
    }

    /// The patch for the text-showing operation `op`; nil when the same form is being edited from another place.
    func patch(_ place: Place, _ op: Int) -> ShowPatch? {
        guard let unitEdit = edit(place) else { return nil }
        if let known = unitEdit.patches[op] { return known }
        let created = ShowPatch(place.unit.operations[op])
        unitEdit.patches[op] = created
        return created
    }

    @discardableResult
    func replace(_ place: Place, _ start: Int, _ end: Int, _ bytes: [UInt8]) -> Bool {
        guard let unitEdit = edit(place) else { return false }
        unitEdit.splices.append(Splice(start: start, end: end, bytes: bytes))
        return true
    }

    @discardableResult
    func replace(_ place: Place, _ start: Int, _ end: Int, _ text: String) -> Bool {
        replace(place, start, end, Latin1.bytes(text))
    }

    @discardableResult
    func insert(_ place: Place, _ at: Int, _ bytes: [UInt8]) -> Bool { replace(place, at, at, bytes) }

    /// Replaces the operation `op` with `text` (nothing deletes it).
    @discardableResult
    func replaceOperation(_ place: Place, _ op: Int, _ text: String) -> Bool {
        let o = place.unit.operations[op]
        return replace(place, o.start, o.end, text)
    }

    /// Registers a resource under a name not used anywhere on the page and returns it; nil when the stream cannot be edited.
    func addResource(_ place: Place, _ category: String, _ value: PdfObject) -> String? {
        guard let unitEdit = edit(place) else { return nil }
        let name = newName()
        unitEdit.resources.append(Resource(category: category, name: name, value: { value }))
        return name
    }

    func append(_ content: [UInt8], _ resources: [(category: String, name: String, value: PdfObject)] = []) {
        appended.append(content)
        guard let unitEdit = edit(Place(scan.pageUnit, nil)) else { return }
        for (category, name, value) in resources { unitEdit.resources.append(Resource(category: category, name: name, value: { value })) }
    }

    /// A name for a resource of appended content, free on the page.
    func newName() -> String {
        var used = names ?? usedNames()
        var n = 1
        while true {
            let name = "LzE\(n)"
            if used.insert(name).inserted {
                names = used
                return name
            }
            n += 1
        }
    }

    private func usedNames() -> Set<String> {
        var found = Set<String>()
        func collect(_ resources: PdfDictionary?) {
            guard let resources else { return }
            for (_, value) in resources.entries {
                if let category = document.resolve(value) as? PdfDictionary {
                    for entry in category.entries { found.insert(entry.key) }
                }
            }
        }
        collect(page.resources)
        for unit in scan.forms.values {
            if let form = unit.form { collect(document.dict(form.dictionary, "Resources")) }
        }
        return found
    }

    /// Writes the changes to the document. Conflicts are found first and thrown before any object is touched.
    func apply() throws {
        var work: [Work] = []
        var done = Set<ObjectIdentifier>()
        while true {
            var next: UnitEdit?
            for unit in order {
                guard let candidate = edits[unit], !done.contains(ObjectIdentifier(candidate)) else { continue }
                if next == nil || candidate.depth > (next?.depth ?? 0) { next = candidate }
            }
            guard let unitEdit = next else { break }
            done.insert(ObjectIdentifier(unitEdit))
            let splices = try compile(unitEdit)
            let data = Splices.apply(unitEdit.unit.data, splices)
            if let visit = unitEdit.visit, isShared(visit) {
                guard let parent = edit(Place(visit.parentUnit, visit.parent)) else {
                    throw EditConflictException("The form is painted from two places.")
                }
                let name = newName()
                let doOp = visit.parentUnit.operations[visit.doOperation]
                parent.splices.append(Splice(start: doOp.start, end: doOp.end, bytes: Latin1.bytes(PdfName(name).description + " Do")))
                let item = Work(unitEdit, data, true)
                parent.resources.append(Resource(category: "XObject", name: name, value: { item.reference ?? PdfNull.instance }))
                work.append(item)
            } else {
                work.append(Work(unitEdit, data, false))
            }
        }

        // A form is rewritten in place, which discard cannot take back, so the page is checked before any is written.
        for item in work where item.edit.visit == nil { item.plan = try planPage(item.edit) }
        for item in work {
            if let visit = item.edit.visit { try writeForm(item, visit) } else { try writePage(item) }
        }
    }

    private func compile(_ unitEdit: UnitEdit) throws -> [Splice] {
        var all = unitEdit.splices
        for op in unitEdit.patches.keys.sorted() {
            if let patch = unitEdit.patches[op] { all.append(patch.compile()) }
        }
        let sorted = all.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.end != b.element.end { return a.element.end < b.element.end }
            return a.offset < b.offset
        }.map { $0.element }
        var i = 1
        while i < sorted.count {
            if sorted[i - 1].end > sorted[i].start { throw EditConflictException("Two changes touch the same operators.") }
            i += 1
        }
        return sorted
    }

    private func writeForm(_ item: Work, _ visit: FormVisit) throws {
        let target: PdfStream
        if item.copy {
            target = PdfStream(visit.form.dictionary.copy(), data: item.data)
            item.reference = try document.add(target)
        } else {
            target = visit.form
        }
        Self.setData(target, item.data)
        if item.edit.resources.isEmpty { return }
        let enclosing: PdfDictionary?
        if let parent = visit.parent { enclosing = document.dict(parent.form.dictionary, "Resources") } else { enclosing = page.resources }
        let own = document.dict(target.dictionary, "Resources")
        let resources: PdfDictionary
        if let own, !item.copy { resources = own } else { resources = (own ?? enclosing)?.copy() ?? PdfDictionary() }
        target.dictionary["Resources"] = resources
        addResources(resources, item.edit.resources, copy: true)
    }

    private func addResources(_ resources: PdfDictionary, _ entries: [Resource], copy: Bool) {
        for entry in entries {
            let category: PdfDictionary
            if let existing = document.dict(resources, entry.category) {
                category = copy ? existing.copy() : existing
            } else {
                category = PdfDictionary()
            }
            category[entry.name] = entry.value()
            resources[entry.category] = category
        }
    }

    private static func setData(_ stream: PdfStream, _ decoded: [UInt8]) {
        stream.dictionary["Filter"] = PdfName("FlateDecode")
        stream.dictionary.remove("DecodeParms")
        stream.dictionary.remove("DP")
        stream.dictionary.remove("F")
        stream.data = PdfFilterEncoders.flate(decoded)
    }

    private func newStream(_ like: PdfDictionary?, _ decoded: [UInt8]) -> PdfStream {
        let stream = PdfStream(like?.copy() ?? PdfDictionary(), data: [])
        stream.dictionary.remove("Length")
        Self.setData(stream, decoded)
        return stream
    }

    private func planPage(_ unitEdit: UnitEdit) throws -> PagePlan {
        let parts = readParts()
        let splices = try compile(unitEdit)
        // Groups of neighbouring parts, merged when a change spans the break between them.
        var groups: [(lo: Int, hi: Int)] = []
        for s in splices {
            let a = Self.partAt(parts, s.start), b = Self.partAt(parts, s.end)
            if a < 0 || b < 0 { throw EditConflictException("A change lies outside the page content.") }
            var merged = (lo: a, hi: b)
            var kept: [(lo: Int, hi: Int)] = []
            for g in groups {
                if g.lo <= merged.hi && merged.lo <= g.hi {
                    merged = (Swift.min(g.lo, merged.lo), Swift.max(g.hi, merged.hi))
                } else {
                    kept.append(g)
                }
            }
            kept.append(merged)
            groups = kept
        }
        let length = scan.pageUnit.data.count
        for g in groups where parts[g.lo].start < 0 || parts[g.hi].end > length || parts[g.lo].start > parts[g.hi].end {
            throw EditConflictException("A change lies outside the page content.")
        }
        return PagePlan(parts: parts, splices: splices, groups: groups)
    }

    private func writePage(_ item: Work) throws {
        let unitEdit = item.edit
        guard let plan = item.plan else { return }
        let (parts, splices, groups) = (plan.parts, plan.splices, plan.groups)
        let items = contentItems()
        var replaced: [Int: (hi: Int, ref: PdfObject)] = [:]
        let data = scan.pageUnit.data
        for (lo, hi) in groups.sorted(by: { $0.lo < $1.lo }) {
            let from = parts[lo].start, to = parts[hi].end
            if from < 0 || to > data.count || from > to { throw EditConflictException("A change lies outside the page content.") }
            let inside = splices.filter { $0.start >= from && $0.end <= to }.map { Splice(start: $0.start - from, end: $0.end - from, bytes: $0.bytes) }
            let bytes = Splices.apply(Array(data[from..<to]), inside)
            replaced[parts[lo].item] = (parts[hi].item, try document.add(newStream(parts[lo].stream.dictionary, bytes)))
        }

        var list: [PdfObject] = []
        var i = 0
        while i < items.count {
            if let r = replaced[i] {
                list.append(r.ref)
                i = r.hi
            } else {
                list.append(items[i])
            }
            i += 1
        }
        if !appended.isEmpty {
            var all = prefix(unitEdit)
            for bytes in appended { all.append(contentsOf: bytes) }
            list.append(try document.add(newStream(nil, all)))
        }
        if !appended.isEmpty && wraps { list.insert(try document.add(newStream(nil, Array("q\n".utf8))), at: 0) }
        if !list.isEmpty {
            let contents: PdfObject = list.count == 1 && items.count <= 1 ? list[0] : PdfArray(list)
            page.dictionary["Contents"] = contents
        }
        if !unitEdit.resources.isEmpty { addResources(ContentResources.forEdit(document, page), unitEdit.resources, copy: false) }
    }

    // A page that leaves state at its top level (a text mode, a clip, a dash) runs inside a q of its own, written
    // first and closed in prefix, so none of it reaches the added content (8.4.2). A stray Q would pop that q
    // and change the page itself, and a page that leaves nothing needs none: it keeps the added content at the
    // level of the page's own, where Order can pass it.
    private var wraps: Bool {
        let states = scan.pageUnit.states
        return !states.stray && states.setsTopLevel
    }

    private func prefix(_ unitEdit: UnitEdit) -> [UInt8] {
        let states = scan.pageUnit.states
        let w = ContentWriter()
        if states.end.inText { w.op("ET") }
        var i = wraps ? 0 : 1
        while i <= states.end.depth {
            w.restore()
            i += 1
        }
        if !wraps, let inverse = states.baseCtm.invert(), states.baseCtm != PdfMatrix.identity { w.concat(inverse) }
        if states.stray && states.setsTopLevel { reset(w, unitEdit, states.end) }
        return w.toArray()
    }

    // With a stray Q there is no q of ours to close, so the state the page left is put back to its initial values
    // (Tables 52, 53 and 57). A clip it left cannot be undone.
    private func reset(_ w: ContentWriter, _ unitEdit: UnitEdit, _ end: OpState) {
        w.textRenderMode(0).charSpacing(0).wordSpacing(0).op("Tz", 100).op("Ts", 0).raw("[] 0 d")
        w.lineWidth(1).op("J", 0).op("j", 0).op("M", 10)
        if end.states.isEmpty { return }
        let initial = PdfDictionary()
        initial["Type"] = PdfName("ExtGState")
        initial["CA"] = PdfNumber(1)
        initial["ca"] = PdfNumber(1)
        initial["BM"] = PdfName("Normal")
        initial["SMask"] = PdfName("None")
        let name = newName()
        unitEdit.resources.append(Resource(category: "ExtGState", name: name, value: { initial }))
        w.graphicsState(name)
    }

    private struct Part {
        let item: Int
        let stream: PdfStream
        let start: Int
        let end: Int
    }

    private func contentItems() -> [PdfObject] {
        let contents = document.resolve(page.dictionary["Contents"])
        if let array = contents as? PdfArray { return array.items }
        if contents is PdfStream, let raw = page.dictionary["Contents"] { return [raw] }
        return []
    }

    // The streams as PdfPage.Contents joins them: decoded, a newline between, unreadable ones left out.
    private func readParts() -> [Part] {
        var parts: [Part] = []
        let items = contentItems()
        var at = 0
        var room = 256 << 20
        for i in 0..<items.count {
            guard let stream = document.resolve(items[i]) as? PdfStream else { continue }
            let length: Int
            do {
                length = try document.data(stream, room).count
            } catch {
                continue
            }
            room = Swift.max(0, room - length - 1)
            if !parts.isEmpty { at += 1 }
            parts.append(Part(item: i, stream: stream, start: at, end: at + length))
            at += length
        }
        return parts
    }

    private static func partAt(_ parts: [Part], _ position: Int) -> Int {
        for i in 0..<parts.count where position >= parts[i].start && position <= parts[i].end { return i }
        return -1
    }

    // A form inside a copied form is reached by the copy too, so it is shared whenever an enclosing one is.
    private func isShared(_ visit: FormVisit) -> Bool {
        if visit.unit.visits > 1 { return true }
        if let parent = visit.parent, isShared(parent) { return true }
        let counts = references ?? countReferences()
        references = counts
        if counts[visit.form.number, default: 0] > 1 { return true }
        let owner = visit.parent?.form.dictionary ?? page.dictionary
        guard let raw = owner["Resources"] else { return true }
        if let r = raw as? PdfReference, counts[r.number, default: 0] > 1 { return true }
        if let x = document.dict(owner, "Resources")?["XObject"] as? PdfReference { return counts[x.number, default: 0] > 1 }
        return false
    }

    private func countReferences() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        var stack: [PdfObject] = []
        for number in document.objectNumbers {
            guard let root = document.get(number) else { continue }
            stack.append(root)
            while let top = stack.popLast() {
                switch top {
                case let r as PdfReference: counts[r.number, default: 0] += 1
                case let d as PdfDictionary: for entry in d.entries { stack.append(entry.value) }
                case let a as PdfArray: for item in a.items { stack.append(item) }
                case let s as PdfStream: stack.append(s.dictionary)
                default: break
                }
            }
        }
        return counts
    }
}

enum Splices {
    /// The data with sorted, non-overlapping splices applied.
    static func apply(_ data: [UInt8], _ splices: [Splice]) -> [UInt8] {
        if splices.isEmpty { return data }
        var output: [UInt8] = []
        output.reserveCapacity(data.count + 64)
        var at = 0
        for s in splices {
            let start = Swift.min(Swift.max(s.start, at), data.count)
            output.append(contentsOf: data[at..<start])
            if let first = s.bytes.first, let last = s.bytes.last {
                // Inserted operators must not run into the token on either side of them (7.2.3).
                if let before = output.last, isRegular(before) && isRegular(first) { output.append(0x20) }
                output.append(contentsOf: s.bytes)
                if s.end < data.count && isRegular(last) && isRegular(data[s.end]) { output.append(0x20) }
            }
            at = Swift.max(at, Swift.min(s.end, data.count))
        }
        output.append(contentsOf: data[at...])
        return output
    }

    private static func isRegular(_ b: UInt8) -> Bool {
        b > 32 && b < 127 && !Array("()<>[]{}/%".utf8).contains(b)
    }
}
