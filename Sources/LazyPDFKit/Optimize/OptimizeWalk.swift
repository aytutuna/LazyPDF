import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeWalk.cs: a walk of every page and its current appearances that
// remembers which resource dictionaries it reached. What a dictionary lists but the walk never reached may be used
// by content nobody ran (soft mask groups, other appearance states, Type 3 glyph procedures, forms past the
// interpreter's limits), so callers must treat it as unseen. A dictionary shared with content that did not run
// counts as unseen too. `complete` is false when no such reading can be trusted.
//
// The C# visitor is built bare and given the document by Walk; here the document is given to the initialiser.

class OptimizeWalk: ContentVisitor {
    // The interpreter runs nothing of a form past these.
    private static let maxFormSize = 64 << 20
    private static let maxFormOperations = 1_000_000
    // What PdfPage.Contents stops reading at.
    private static let maxContentSize = 256 << 20

    private var reachedResources = Set<ObjectIdentifier>()
    private var unrunResources = Set<ObjectIdentifier>()
    private var walkedForms = Set<ObjectIdentifier>()
    private var bases: [PdfMatrix] = []
    private var patternBases: [ObjectIdentifier: PdfMatrix?] = [:]
    private let document: PdfDocument

    /// Every use was walked: no run was cut short, no stream was unreadable, and no content that needs its caller's resources went unrun.
    private(set) var complete = true

    /// User space units per point on the page being walked (14.11.2.3).
    private(set) var userUnit = 1.0

    init(_ document: PdfDocument) {
        self.document = document
        super.init()
    }

    func reached(_ resources: PdfDictionary) -> Bool {
        reachedResources.contains(ObjectIdentifier(resources)) && !unrunResources.contains(ObjectIdentifier(resources))
    }

    func walk() {
        let interpreter = ContentInterpreter(document)
        for page in document.pages {
            userUnit = page.userUnit
            patternBases.removeAll()
            if let resources = page.resources { reachedResources.insert(ObjectIdentifier(resources)) }
            if !readable(page) { complete = false }
            interpreter.run(page, self)
            if interpreter.isTruncated { complete = false }
            for (form, matrix) in PageAppearances.of(document, page) {
                runAppearance(interpreter, page, form, matrix)
                if interpreter.isTruncated { complete = false }
            }
        }
        let groups = softMaskGroups()
        for (_, value) in PdfGraph.objects(document) {
            if let stream = value as? PdfStream, Self.isForm(document, stream),
               !walkedForms.contains(ObjectIdentifier(stream)) || groups.contains(ObjectIdentifier(stream)) {
                withhold(stream)
            }
        }
        // Glyph procedures are never run, so their resources and their caller's are both unseen.
        for dictionary in PdfGraph.allDictionaries(document) {
            if document.name(dictionary, "Subtype") != "Type3" { continue }
            if let own = document.dict(dictionary, "Resources") {
                unrunResources.insert(ObjectIdentifier(own))
            } else if (document.dict(dictionary, "CharProcs")?.entries ?? []).contains(where: { entry in
                (document.resolve(entry.value) as? PdfStream).map { usesResources($0) } ?? false
            }) {
                complete = false
            }
        }
    }

    /// Whether the interpreter runs the stream as content of its own: a form (a stream with a /BBox and no /Subtype counts as one) or a tiling pattern.
    static func isForm(_ document: PdfDocument, _ stream: PdfStream) -> Bool {
        let subtype = document.name(stream.dictionary, "Subtype")
        return subtype == "Form" || (subtype == nil && stream.dictionary.containsKey("BBox")) || document.integer(stream.dictionary, "PatternType") == 1
    }

    // A soft mask group is never run, so a form that is also painted may be drawn in this other use at a size nobody measured.
    private func softMaskGroups() -> Set<ObjectIdentifier> {
        var groups = Set<ObjectIdentifier>()
        for dictionary in PdfGraph.allDictionaries(document) {
            if let mask = document.dict(dictionary, "SMask"), let group = document.resolve(mask["G"]) as? PdfStream {
                groups.insert(ObjectIdentifier(group))
            }
        }
        return groups
    }

    private func withhold(_ stream: PdfStream) {
        if let own = document.dict(stream.dictionary, "Resources") {
            unrunResources.insert(ObjectIdentifier(own))
        } else if usesResources(stream) {
            complete = false
        }
    }

    override func paintPath(_ context: ContentContext, _ path: PathInfo) {
        if path.fill { notePattern(context.state.fillColor) }
        if path.stroke { notePattern(context.state.strokeColor) }
    }

    // The interpreter runs a tiling pattern's cell once per run, against the base matrix of the first stream that paints with it (8.7.3).
    private func notePattern(_ color: PdfColor) {
        guard let pattern = color.pattern as? PdfStream, document.integer(pattern.dictionary, "PatternType") == 1 else { return }
        let from = bases.last
        let id = ObjectIdentifier(pattern)
        if let known = patternBases[id] {
            if !Self.sameScale(known, from) { withhold(pattern) }
        } else {
            patternBases[id] = .some(from)
        }
    }

    private static func sameScale(_ a: PdfMatrix?, _ b: PdfMatrix?) -> Bool {
        if let x = a, let y = b {
            return abs(x.a - y.a) < 1e-6 && abs(x.b - y.b) < 1e-6 && abs(x.c - y.c) < 1e-6 && abs(x.d - y.d) < 1e-6
        }
        return a == nil && b == nil
    }

    override func endForm(_ context: ContentContext, _ form: FormInfo) {
        _ = bases.popLast()
    }

    override func beginForm(_ context: ContentContext, _ form: FormInfo) {
        bases.append(form.matrix)
        if !walkedForms.insert(ObjectIdentifier(form.stream)).inserted { return }
        if let resources = document.dict(form.stream.dictionary, "Resources") { reachedResources.insert(ObjectIdentifier(resources)) }
        do {
            _ = try ContentParser.parse(document.data(form.stream, Self.maxFormSize), Self.maxFormOperations)
        } catch {
            complete = false
        }
    }

    // An appearance without /Resources runs in the page's (7.8.3), which the interpreter does not know for a form run on its own.
    private func runAppearance(_ interpreter: ContentInterpreter, _ page: PdfPage, _ form: PdfStream, _ matrix: PdfMatrix) {
        patternBases.removeAll()
        guard !form.dictionary.containsKey("Resources"), let borrowed = page.resources else {
            interpreter.run(form, self, matrix)
            return
        }
        form.dictionary["Resources"] = borrowed
        interpreter.run(form, self, matrix)
        form.dictionary.remove("Resources")
    }

    private func readable(_ page: PdfPage) -> Bool {
        var room = Self.maxContentSize
        let contents = document.resolve(page.dictionary["Contents"])
        let items: [PdfObject] = (contents as? PdfArray)?.items ?? [contents ?? PdfNull.instance]
        for item in items {
            guard let stream = document.resolve(item) as? PdfStream else { continue }
            do {
                room = max(0, room - (try document.data(stream, room)).count - 1)
            } catch {
                return false
            }
        }
        return true
    }

    // Whether content that never ran names a font, XObject or graphics state, which it would look up in its caller's resources.
    private func usesResources(_ stream: PdfStream) -> Bool {
        do {
            return try ContentParser.parse(document.data(stream, Self.maxFormSize), Self.maxFormOperations).contains { ["Tf", "Do", "gs"].contains($0.operator) }
        } catch {
            return true
        }
    }
}
