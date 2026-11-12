import Foundation

// Twin of windows/LazyPDF.Core/Redaction/PdfRedactor.Page.cs: what is known of a marked page before anything is changed, and
// how a page is rewritten, or made a picture.

extension PdfRedactor {
    private static let maxOpenQ = 1000
    private static let minNeedle = 3

    struct Plan {
        let page: PdfPage
        let marks: [RedactionMark]
        let areas: [MarkArea]
        let hit: Int
        let scan: RedactionScan?
        var understood: Bool
        let reach: Set<Int>
        let entries: StreamCounts
    }

    // What a viewer takes from a page dictionary (Table 30). The rest, the thumbnail and the private keys among it, is data the page has no use for.
    private static let pageKeys =
        ["Type", "Parent", "Contents", "Resources", "MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox", "BoxColorInfo", "Rotate", "UserUnit", "Group", "Annots", "B", "Dur", "Trans", "AA", "StructParents", "Tabs"]

    func examine(_ work: PdfDocument, _ page: PdfPage, _ marks: [RedactionMark], _ interpreter: ContentInterpreter, _ needles: inout NeedleSet) -> Plan {
        let areas = marks.flatMap { $0.quads }.map { MarkArea.of($0) }.filter { $0.isUsable }
        let hit = Self.addNeedles(TextPage.create(interpreter, page), areas, &needles)
        let scan = RedactionScan(areas)
        let walk = RedactionWalk(work)
        interpreter.run(page, scan)
        let understood = !interpreter.isTruncated && !scan.unhandled && walk.page(page) && walk.annotations(page)
        var reach = Set<Int>()
        RedactionObjects.collect(work, page.dictionary, &reach, ["B"])
        return Plan(page: page, marks: marks, areas: areas, hit: hit, scan: scan, understood: understood, reach: reach, entries: walk.entries)
    }

    // A picture or form that is cut where it meets a mark has to be shown nowhere else, on this page, on another marked one or by
    // an annotation: the cut is a copy, and every other use still names the original. A page with such a use becomes a picture.
    static func reconcile(_ plans: [Plan]) -> [Plan] {
        var cut = Set<ObjectIdentifier>()
        for plan in plans where plan.understood {
            if let scan = plan.scan { cut.formUnion(scan.edited.identifiers) }
        }
        return plans.map { plan in
            guard plan.understood, let scan = plan.scan else { return plan }
            var result = plan
            if cut.contains(where: { plan.entries.count($0) != scan.edited.count($0) }) { result.understood = false }
            return result
        }
    }

    func redactPage(_ work: PdfDocument, _ plan: Plan, _ options: RedactionOptions, _ font: PdfDrawFont?, _ rewriter: ContentRewriter,
                    _ needles: inout NeedleSet, _ painted: inout Set<Int>, _ flattened: inout [Int]) throws -> (PageRedaction, RedactionStructure.Tagged.Value) {
        let (page, marks, areas) = (plan.page, plan.marks, plan.areas)
        if plan.understood, let scan = plan.scan {
            var content = RedactionResources.dropIdleFonts(try rewriter.rewrite(scan.root, page.contents(), page.dictionary, page.resources, false))
            var fontName = ""
            if let font, marks.contains(where: { !($0.overlayText ?? options.overlayText ?? "").isEmpty }) {
                fontName = ContentResources.add(work, work.dict(page.dictionary, "Resources") ?? PdfDictionary(), "Font", font.reference, "RdF")
            }
            content = Self.enclose(content, RedactionOverlay.build(marks, options, font, fontName))
            // What was written is read again by the same rule; a page that fails it is a bug of the rewrite, not a reason to keep it.
            let probe = RedactionWalk(work)
            let followed = probe.page(page, content)
            if followed { RedactionResources.rebuild(work, page.dictionary, probe) }
            let walk = RedactionWalk(work)
            if followed && walk.page(page, content) {
                page.dictionary["Contents"] = try Self.store(work, content)
                for (key, _) in page.dictionary.entries where !Self.pageKeys.contains(key) { page.dictionary.remove(key) }
                let (annotations, fields) = try Self.removeAnnotations(work, page, { a in areas.contains { Geometry.touches(a.rect, $0) } }, &needles, false)
                _ = Self.keepPainted(work, page, walk, &painted)
                return (PageRedaction(page.index, scan.glyphs, scan.images, scan.paths, annotations, fields), scan.marked)
            }
        }
        if options.renderer == nil { throw InvalidOperationException(RedactionText.needsPicture(page.index)) }
        // Everything the page showed is gone, so every content item of its tags is.
        for number in plan.reach.sorted() {
            if let stream = work.get(number) as? PdfStream { rewriter.replaced.insert(stream) }
        }
        let (removed, cleared) = try Self.removeAnnotations(work, page, { a in plan.areas.contains { Geometry.touches(a.rect, $0) } }, &needles, true)
        try RedactionFlatten.page(work, page, marks, options, font)
        Self.keepBoxes(work, page, &painted)
        flattened.append(page.index)
        return (PageRedaction(page.index, plan.hit, 0, 0, removed, cleared), [:])
    }

    static func store(_ work: PdfDocument, _ content: [UInt8]) throws -> PdfReference {
        let dictionary = PdfDictionary()
        dictionary["Filter"] = PdfName("FlateDecode")
        return try work.add(PdfStream(dictionary, data: PdfFilterEncoders.flate(content)))
    }

    // The overlay goes after the page in a clean state, whatever the page leaves open (ISO 32000-1 8.4.2).
    private static func enclose(_ source: [UInt8], _ overlay: [UInt8]) -> [UInt8] {
        var depth = 0, lowest = 0, marked = 0
        var text = false
        let operations = ContentParser.parse(source)
        // Operands with no operator after them, or a string never closed, would swallow what follows.
        let content = Array(source[0..<min(source.count, operations.last?.end ?? 0)])
        for op in operations {
            switch op.operator {
            case "q": depth += 1
            case "Q":
                depth -= 1
                lowest = min(lowest, depth)
            case "BT": text = true
            case "ET": text = false
            case "BMC", "BDC": marked += 1
            case "EMC": marked = max(0, marked - 1)
            default: break
            }
        }
        let opened = min(max(1 - lowest, 1), maxOpenQ)
        let head = ContentWriter()
        for _ in 0..<opened { head.save() }
        let tail = ContentWriter()
        if text { tail.endText() }
        for _ in 0..<min(marked, maxOpenQ) { tail.endMarked() }
        for _ in 0..<min(max(opened + depth, 0), maxOpenQ) { tail.restore() }
        return head.toArray() + content + [0x0A] + tail.toArray() + overlay
    }

    // The words of the page under each mark, to look for in places the marks do not reach.
    private static func addNeedles(_ text: TextPage, _ areas: [MarkArea], _ needles: inout NeedleSet) -> Int {
        text.requirePageContent()
        var hits = 0
        for area in areas {
            var start = -1
            for i in 0...text.chars.count {
                let hit = i < text.chars.count && Geometry.glyphMeets(Geometry.corners(text.chars[i].quad), area)
                if hit { hits += 1 }
                if hit && start < 0 {
                    start = i
                    continue
                }
                if hit || start < 0 { continue }
                for part in text.getText(TextRange(start, i)).unicodeScalars.split(whereSeparator: { $0 == "\n" || $0 == "\t" }) {
                    var scalars = String.UnicodeScalarView()
                    scalars.append(contentsOf: part)
                    let phrase = DotNetText.words(String(scalars))
                    if phrase.utf16.filter({ !DotNetText.isWhiteSpace($0) }).count >= minNeedle { needles.insert(phrase) }
                }
                start = -1
            }
        }
        return hits
    }

    static func addNeedle(_ needles: inout NeedleSet, _ text: String?) {
        if let text, text.utf16.filter({ !DotNetText.isWhiteSpace($0) }).count >= minNeedle { needles.insert(DotNetText.trim(text)) }
    }

    // The annotations under a mark go with their fields, and what they said is looked for in the output. On a page that becomes a picture
    // every other annotation goes too, but a widget not under a mark only leaves its field when it was the field's last.
    private static func removeAnnotations(_ work: PdfDocument, _ page: PdfPage, _ meets: (PdfAnnotation) -> Bool, _ needles: inout NeedleSet,
                                          _ flat: Bool) throws -> (annotations: Int, fields: Int) {
        let all = PdfAnnotations.read(work, page)
        let hit = all.filter(meets)
        var widgets = Set(hit.filter { $0.type == .widget }.map { ObjectIdentifier($0.dictionary) })
        var fields = 0
        while !widgets.isEmpty {
            let form = PdfForm.read(work)
            guard let field = form.fields.first(where: { f in f.widgets.contains { widgets.contains(ObjectIdentifier($0.dictionary)) } }) else { break }
            for widget in field.widgets { widgets.remove(ObjectIdentifier(widget.dictionary)) }
            addNeedle(&needles, field.value)
            try form.remove(field)
            fields += 1
        }
        var rest = Set<ObjectIdentifier>()
        if flat {
            let hitIds = Set(hit.map { ObjectIdentifier($0.dictionary) })
            for a in all where !hitIds.contains(ObjectIdentifier(a.dictionary)) { rest.insert(ObjectIdentifier(a.dictionary)) }
        }
        for other in all where other.type == .widget && rest.contains(ObjectIdentifier(other.dictionary)) {
            let form = PdfForm.read(work)
            guard let widget = form.fields.flatMap({ $0.widgets }).first(where: { $0.dictionary === other.dictionary }) else { continue }
            if (widget.field?.widgets.count ?? 1) <= 1 { fields += 1 }
            try form.remove(widget)
        }
        // A widget no field owns is only an annotation.
        let writer = PdfAnnotationWriter(work)
        var removed = 0
        for a in hit where a.type != .widget || widgets.contains(ObjectIdentifier(a.dictionary)) {
            addNeedle(&needles, a.contents)
            if writer.delete(a) { removed += 1 }
        }
        for a in PdfAnnotations.read(work, page) where rest.contains(ObjectIdentifier(a.dictionary)) {
            if writer.delete(a) { removed += 1 }
        }
        return (removed, fields)
    }
}
