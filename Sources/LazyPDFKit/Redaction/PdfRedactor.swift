import Foundation

// Twin of windows/LazyPDF.Core/Redaction/PdfRedactor.cs: removes what is under marks from a document for good. Marking writes
// /Redact annotations that can be looked over and nothing is removed; applying reads the marks, takes the text, pictures,
// shapes, annotations and form fields under them out of a copy of the file and covers the places. A page that cannot be
// followed to its end by the rule in `RedactionWalk` becomes a picture of itself instead. The result is always a new file
// written whole (`PdfDocument.saveRewrite`): an earlier revision of the same file would still hold what was removed, so the
// document itself is not changed and there is no way to apply by appending.
//
// The removed words are kept in `NeedleSet`, a list that holds each once by its UTF-16 units: a Swift Set<String> would merge
// two spellings that differ only in canonical equivalence, and the bytes searched for them differ.

public final class PdfRedactor {
    /// The words found under the marks, once each, in the order they were found.
    struct NeedleSet {
        private(set) var list: [String] = []
        private var seen = Set<OrdinalString>()

        mutating func insert(_ text: String) {
            if seen.insert(OrdinalString(text)).inserted { list.append(text) }
        }

        /// `needles.Order(StringComparer.Ordinal)`.
        var ordered: [String] { list.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) } }
    }

    let document: PdfDocument
    let fonts: FontSource?
    let images: ImageCodec?

    public init(_ document: PdfDocument, _ fonts: FontSource? = nil, _ images: ImageCodec? = nil) {
        self.document = document
        self.fonts = fonts
        self.images = images
    }

    /// The marks the document holds as /Redact annotations, in page order.
    public func readMarks() -> [RedactionMark] {
        var marks: [RedactionMark] = []
        for a in PdfAnnotations.readAll(document) where a.type == .redact {
            let quads: [TextQuad]
            if !a.quads.isEmpty {
                quads = a.quads.map { TextQuad($0.x3, $0.y3, $0.x4, $0.y4, $0.x2, $0.y2, $0.x1, $0.y1) }
            } else {
                quads = RedactionMark.fromRect(a.pageIndex, a.rect).quads
            }
            var fill: [Double]?
            if let color = a.interiorColor, [1, 3, 4].contains(color.count) { fill = color }
            marks.append(RedactionMark(a.pageIndex, quads, fill, PdfText.read(document, a.dictionary, "OverlayText")))
        }
        return marks
    }

    /// Writes a /Redact annotation for each mark. The edit session commits them; nothing is removed.
    public func addMarks(_ marks: [RedactionMark], _ info: AnnotationInfo? = nil) throws -> [PdfAnnotation] {
        let writer = PdfAnnotationWriter(document, fonts)
        var added: [PdfAnnotation] = []
        for mark in marks {
            if mark.page < 0 || mark.page >= document.pages.count || mark.quads.isEmpty { continue }
            let quads = mark.quads.map { MarkupQuad($0.x3, $0.y3, $0.x2, $0.y2, $0.x0, $0.y0, $0.x1, $0.y1) }
            added.append(try writer.addRedact(document.pages[mark.page], quads, info: info, fill: mark.fill, overlayText: mark.overlayText))
        }
        return added
    }

    /// Applies the document's own /Redact annotations.
    public func applyMarked(_ options: RedactionOptions? = nil, _ values: [RedactionValueMatch]? = nil) throws -> RedactionResult {
        try apply(readMarks(), options, values)
    }

    /// Removes what is under the marks and returns the new file. A page with marks that is not understood in full, by the
    /// rule in `RedactionWalk`, becomes a picture of itself drawn by `RedactionOptions.renderer`; without one, or when it
    /// cannot draw the page, this throws `InvalidOperationException` with `RedactionText.needsPicture` or
    /// `RedactionText.notDrawn`. It throws the same with `RedactionText.noFont` when overlay text needs a font that cannot
    /// be found. The document is not changed in any case. `values` are hits in annotation contents and field values (see
    /// `RedactionFinder.findInValues`): the text found is replaced by `RedactionOptions.overlayText`, or removed without one,
    /// and the appearance is drawn again.
    public func apply(_ marks: [RedactionMark], _ options: RedactionOptions? = nil, _ values: [RedactionValueMatch]? = nil) throws -> RedactionResult {
        let options = options ?? RedactionOptions()
        var chosen: [RedactionMark] = []
        for var mark in marks where mark.page >= 0 && mark.page < document.pages.count {
            mark.quads = mark.quads.filter { ($0.x0 + $0.y0 + $0.x1 + $0.y1 + $0.x2 + $0.y2 + $0.x3 + $0.y3).isFinite }
            if !mark.quads.isEmpty { chosen.append(mark) }
        }
        let work = try PdfDocument.open(try document.saveRewrite())
        Self.pushDownResources(work)

        var pages: [PageRedaction] = []
        var needles = NeedleSet()
        // First, since removing annotations under a mark shifts the indexes the hits were found at.
        let rewritten = values.map { rewriteValues(work, $0, options, &needles) } ?? [:]

        var font: PdfDrawFont?
        var texts: [String] = []
        for mark in chosen {
            if let text = mark.overlayText ?? options.overlayText, !text.isEmpty { texts.append(text) }
        }
        if !texts.isEmpty {
            guard let drawn = try PdfFontEmbedder(work, fonts).add(options.fontFamily, .bold, texts) else {
                throw InvalidOperationException(RedactionText.noFont)
            }
            font = drawn
        }

        var tagged: RedactionStructure.Tagged = [:]
        let rewriter = ContentRewriter(work, ImageRedactor(work, images))
        let interpreter = ContentInterpreter(work)
        interpreter.walkPatterns = false
        var plans: [Plan] = []
        var grouped: [Int: [RedactionMark]] = [:]
        for mark in chosen { grouped[mark.page, default: []].append(mark) }
        for key in grouped.keys.sorted() {
            plans.append(examine(work, work.pages[key], grouped[key] ?? [], interpreter, &needles))
        }
        plans = Self.reconcile(plans)
        if options.flattenMarkedPages {
            plans = plans.map { (p: Plan) -> Plan in
                var q = p
                q.understood = false
                return q
            }
        }
        if options.renderer == nil, let stuck = plans.first(where: { !$0.understood }) {
            throw InvalidOperationException(RedactionText.needsPicture(stuck.page.index))
        }

        // What the marked pages reach now is all emptied at the end except what they still paint.
        var reached = Set<Int>()
        for plan in plans { reached.formUnion(plan.reach) }
        var painted = Set<Int>()
        var flattened: [Int] = []
        for plan in plans {
            let (redaction, counts) = try redactPage(work, plan, options, font, rewriter, &needles, &painted, &flattened)
            pages.append(redaction)
            tagged[plan.page.reference.number] = counts
        }
        for (page, hit) in rewritten {
            if let at = pages.firstIndex(where: { $0.page == page }) {
                pages[at].values = hit.count
                pages[at].valuesWhole = hit.whole
            } else {
                pages.append(PageRedaction(page, 0, 0, 0, 0, 0, hit.count, valuesWhole: hit.whole))
            }
        }
        pages.sort { $0.page < $1.page }
        let marked = Set(plans.map { $0.page.index })
        var unfollowed: [Int] = []
        if !reached.isEmpty {
            for page in work.pages where !marked.contains(page.index) {
                if !Self.keep(work, page, reached, &painted) { unfollowed.append(page.index) }
            }
        }

        let signatures = Self.removeSignatures(work)
        Self.cleanForm(work)
        try RedactionStructure.prune(work, tagged, rewriter.replaced, Set(flattened.map { work.pages[$0].reference.number }))
        RedactionObjects.sweep(work, reached, &painted)
        let findings = try RedactionMetadata.scan(work, needles.list, options.changeMetadata)

        // The check reads the file as plain bytes; encrypting changes nothing it looks at. An open file gets an /ID
        // of its own, so that it is not tied to the original; the keys of an encrypted one are made from the first.
        var bytes = try work.saveRewrite(PdfSaveOptions(documentId: (0..<16).map { _ in UInt8.random(in: 0...255) }))
        var verification = Self.verify(bytes, chosen, needles.list, Self.distinct(texts))
        if !unfollowed.isEmpty {
            verification = RedactionVerification(verification.problems + unfollowed.map { RedactionText.notFollowed($0) })
        }
        if options.keepEncryption, let security = document.security {
            bytes = try work.saveRewrite(PdfSaveOptions(security: security, documentId: document.firstId ?? []))
        }
        var report = RedactionReport(pages, findings, signatures, options.includeText ? needles.ordered : [])
        report.flattened = flattened
        return RedactionResult(bytes, report, verification)
    }

    // The distinct texts, each once in the order met.
    private static func distinct(_ texts: [String]) -> [String] {
        var seen = Set<OrdinalString>()
        return texts.filter { seen.insert(OrdinalString($0)).inserted }
    }

    // A page without marks keeps what it paints of the objects a redacted page reached; what it only lists is not its own.
    // A page that cannot be followed keeps every stream it lists, but not what its keys happen to name, and the result says it was not checked.
    private static func keep(_ work: PdfDocument, _ page: PdfPage, _ reached: Set<Int>, _ painted: inout Set<Int>) -> Bool {
        var all = Set<Int>()
        RedactionObjects.collect(work, page.dictionary, &all)
        if all.isDisjoint(with: reached) { return true }
        let first = RedactionWalk(work)
        if !first.page(page) {
            RedactionObjects.painted(work, page.dictionary, &painted, RedactionObjects.listing)
            return false
        }
        // Its own lists, so that the ones it shared with a redacted page are not held by it.
        RedactionResources.rebuild(work, page.dictionary, first)
        let walk = RedactionWalk(work)
        walk.page(page)
        return keepPainted(work, page, walk, &painted)
    }

    // False when an appearance cannot be followed: the page then keeps every stream its annotations list, and the result says so.
    static func keepPainted(_ work: PdfDocument, _ page: PdfPage, _ walk: RedactionWalk, _ painted: inout Set<Int>) -> Bool {
        let followed = walk.annotations(page)
        if !followed { RedactionObjects.painted(work, page.dictionary["Annots"], &painted, RedactionObjects.listing) }
        painted.formUnion(walk.used)
        RedactionObjects.paintedStream(work, page.dictionary["Contents"], &painted, RedactionObjects.painting)
        RedactionObjects.painted(work, page.dictionary["Group"], &painted, RedactionObjects.painting)
        keepBoxes(work, page, &painted)
        return followed
    }

    // The boxes and the turn can be objects of their own, shared with pages that were not redacted.
    static func keepBoxes(_ work: PdfDocument, _ page: PdfPage, _ painted: inout Set<Int>) {
        for key in ["MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox", "Rotate", "UserUnit"] {
            RedactionObjects.painted(work, page.dictionary[key], &painted, RedactionObjects.painting)
        }
    }

    // Resources a page takes from the page tree stay in the tree node, and with them the pictures
    // that are cut on the page. Every page gets its own reference and the nodes lose theirs.
    private static func pushDownResources(_ work: PdfDocument) {
        let maxDepth = 256
        var nodes: [PdfDictionary] = []
        var seen = RedactionObjects.Identities()
        // Down from the root by /Kids, as the page list is read, since a /Parent can be missing or point elsewhere.
        func down(_ node: PdfObject?, _ above: PdfObject?, _ depth: Int) {
            guard let dictionary = work.resolve(node) as? PdfDictionary, depth <= maxDepth, seen.insert(dictionary) else { return }
            let inherited = dictionary["Resources"] ?? above
            // A node is told as the page list tells it: /Type /Page is a page, whatever else it holds.
            if work.name(dictionary, "Type") != "Page", let kids = work.resolve(dictionary["Kids"]) as? PdfArray {
                nodes.append(dictionary)
                for kid in kids.items { down(kid, inherited, depth + 1) }
            } else if !dictionary.containsKey("Resources"), let inherited {
                dictionary["Resources"] = inherited
            }
        }
        down(work.catalog["Pages"], nil, 0)
        for node in nodes { node.remove("Resources") }
    }

    // A signature covers bytes that no longer exist in the output.
    private static func removeSignatures(_ work: PdfDocument) -> Int {
        var count = 0
        let signed = work.isSigned
        for number in work.objectNumbers {
            if let field = work.get(number) as? PdfDictionary, work.name(field, "FT") == "Sig", field.containsKey("V") {
                field.remove("V")
                count += 1
            }
        }
        work.catalog.remove("Perms")
        work.catalog.remove("DSS")
        work.dict(work.catalog, "AcroForm")?.remove("SigFlags")
        return count == 0 && signed ? 1 : count
    }

    // Values live in the XFA data too, and a form with no field left has nothing to say.
    private static func cleanForm(_ work: PdfDocument) {
        guard let form = work.dict(work.catalog, "AcroForm") else { return }
        if let fields = work.array(form, "Fields"), fields.items.isEmpty {
            work.catalog.remove("AcroForm")
        } else if work.hasXfa && work.catalog.containsKey("AcroForm") {
            form.remove("XFA")
        }
    }
}
