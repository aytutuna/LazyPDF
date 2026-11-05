import Foundation

// Twin of windows/LazyPDF.Core/Stamps/PdfStamper.cs: adds watermarks, backgrounds, headers, footers and Bates numbers to a
// document as page content, and finds them again. Everything a run adds is marked as an artifact (ISO 32000-1 14.8.2.2) and
// as that run's own through a /LazyPDF key in the content streams, so `list`, `update` and `remove` work on it later, in the
// same session or after a save. A run is one id across the pages it covers. Nothing is saved here; the caller saves the
// document.
//
// `fonts` is where font files come from for text a Standard 14 font cannot draw. A spec with nothing to draw is a caller's
// mistake, a precondition where the C# throws ArgumentException; a font that cannot draw the text throws
// InvalidOperationException with `StampsText.noFont`, which a user's text can cause. Every call that adds objects throws,
// because PdfDocument.add does.

public final class PdfStamper {
    let document: PdfDocument
    private let fonts: FontSource?

    public init(_ document: PdfDocument, _ fonts: FontSource? = nil) {
        self.document = document
        self.fonts = fonts
    }

    @discardableResult
    public func addWatermark(_ spec: WatermarkSpec) throws -> StampRun { try watermark(nextId(), spec) }

    @discardableResult
    public func addBackground(_ spec: BackgroundSpec) throws -> StampRun { try background(nextId(), spec) }

    @discardableResult
    public func addHeaderFooter(_ spec: HeaderFooterSpec) throws -> StampRun { try headerFooter(nextId(), spec) }

    /// Replaces run `id` with a new one under the same id; adds it when there is no such run.
    @discardableResult
    public func update(_ id: Int, _ spec: WatermarkSpec) throws -> StampRun { try replace(id) { try watermark($0, spec) } }

    @discardableResult
    public func update(_ id: Int, _ spec: BackgroundSpec) throws -> StampRun { try replace(id) { try background($0, spec) } }

    @discardableResult
    public func update(_ id: Int, _ spec: HeaderFooterSpec) throws -> StampRun { try replace(id) { try headerFooter($0, spec) } }

    /// The runs on the document, by id.
    public func list() -> [StampInfo] { collect(Array(document.pages)) }

    public func list(_ page: PdfPage) -> [StampInfo] { collect([page]) }

    /// Takes a run off every page; returns the number of pages it was on.
    @discardableResult
    public func remove(_ id: Int) -> Int {
        var pages = 0
        var uses = StampStreams.countUses(document)
        for page in document.pages {
            if !StampStreams.remove(document, page, id, &uses) { continue }
            StampStreams.removeResources(document, page, id)
            pages += 1
        }
        StampLayers.remove(document, id)
        return pages
    }

    /// Removes every run; returns how many there were.
    @discardableResult
    public func removeAll() -> Int {
        let ids = list().map { $0.id }
        for id in ids { remove(id) }
        return ids.count
    }

    // The new run is tried under a spare id first, so that a spec that cannot be drawn leaves the old run alone.
    private func replace(_ id: Int, _ add: (Int) throws -> StampRun) throws -> StampRun {
        let probe = nextId()
        do {
            _ = try add(probe)
        } catch {
            remove(probe)
            throw error
        }
        remove(probe)
        remove(id)
        return try add(id)
    }

    private func collect(_ pages: [PdfPage]) -> [StampInfo] {
        var runs: [Int: (kind: StampKind, label: String?, behind: Bool, pages: [Int])] = [:]
        for page in pages {
            for found in StampStreams.scan(document, page) {
                if runs[found.id] == nil { runs[found.id] = (found.kind, found.label, found.behind, []) }
                runs[found.id]?.pages.append(page.index)
            }
        }
        return runs.keys.sorted().compactMap { id in
            runs[id].map { StampInfo(id: id, kind: $0.kind, label: $0.label, behind: $0.behind, pages: $0.pages) }
        }
    }

    private func nextId() -> Int {
        StampStreams.spare(Set(document.pages.flatMap { StampStreams.scan(document, $0) }.map { $0.id }))
    }

    func targets(_ pages: [Int]?) -> [Int] {
        let count = document.pages.count
        guard let pages else { return Array(0..<count) }
        return Set(pages.filter { $0 >= 0 && $0 < count }).sorted()
    }

    func font(_ family: String, _ style: FontStyles, _ texts: [String]) throws -> PdfDrawFont {
        guard let font = try PdfFontEmbedder(document, fonts).add(family, style, texts) else {
            throw InvalidOperationException(StampsText.noFont)
        }
        return font
    }

    func layer(_ id: Int, _ name: String?) throws -> PdfReference? {
        guard let name, !name.isEmpty else { return nil }
        return try StampLayers.add(document, id, name)
    }

    func opacity(_ opacity: Double) throws -> PdfReference? {
        if opacity >= 1 { return nil }
        let state = PdfDictionary()
        state["Type"] = PdfName("ExtGState")
        let value = PdfNumber(Swift.max(0, opacity))
        state["CA"] = value
        state["ca"] = value
        return try document.add(state)
    }

    /// Puts what the page's content refers to under the run's names and adds the content.
    func finish(_ page: PdfPage, _ canvas: StampCanvas, _ id: Int, _ kind: StampKind, _ label: String?, _ behind: Bool,
                _ font: PdfReference?, _ image: PdfReference?, _ state: PdfReference?, _ layer: PdfReference?) throws {
        let resources = ContentResources.forEdit(document, page)
        if let font { StampStreams.register(document, resources, "Font", StampStreams.fontName(id), font) }
        if let image { StampStreams.register(document, resources, "XObject", StampStreams.imageName(id), image) }
        if let state { StampStreams.register(document, resources, "ExtGState", StampStreams.stateName(id), state) }
        if let layer { StampStreams.register(document, resources, "Properties", StampStreams.layerResourceName(id), layer) }
        try StampStreams.add(document, page, canvas.toArray(), id, kind, label, behind)
    }
}
