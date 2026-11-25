import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/PdfUaChecker.Content.cs: what the pages draw, tagged or artifact (7.1), fonts
// (7.21) and XObjects (7.20), found in one run of the interpreter per page. The fonts are kept in the order they were met,
// because the issues of the fonts come out in it.

private struct SequenceInForm: Hashable {
    let stream: Int
    let mcid: Int
}

private struct FontUse {
    var shown = false
    var noText = false
}

private final class FontUses {
    private(set) var fonts: [PdfFont] = []
    private var uses: [ObjectIdentifier: FontUse] = [:]

    func note(_ font: PdfFont, shown: Bool, noText: Bool) {
        let id = ObjectIdentifier(font)
        if uses[id] == nil { fonts.append(font) }
        var use = uses[id] ?? FontUse()
        use.shown = use.shown || shown
        use.noText = use.noText || noText
        uses[id] = use
    }

    func use(_ font: PdfFont) -> FontUse { uses[ObjectIdentifier(font)] ?? FontUse() }
}

// What a page's content says about itself.
private final class PageContent: ContentVisitor {
    private let known: ((PdfStream?, Int) -> Bool)?
    private var open: [(mark: MarkedContent, form: PdfStream?)] = []

    private(set) var untagged = 0
    private(set) var artifactInTagged = 0
    private(set) var taggedInArtifact = 0
    let fonts = FontUses()

    init(_ known: ((PdfStream?, Int) -> Bool)?) {
        self.known = known
        super.init()
    }

    override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
        if glyph.character.isSpace { return }
        fonts.note(glyph.font, shown: context.state.renderMode != 3, noText: (glyph.unicode ?? "").isEmpty)
        note()
    }

    override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
        note()
    }

    override func paintPath(_ context: ContentContext, _ path: PathInfo) {
        if path.fill || path.stroke { note() }
    }

    override func paintShading(_ context: ContentContext, _ shading: ShadingInfo) {
        note()
    }

    // A sequence is numbered in the stream that holds it, so each is kept with its form.
    override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
        open.append((marked, context.forms.last))
    }

    override func endMarked(_ context: ContentContext, _ marked: MarkedContent) {
        _ = open.popLast()
    }

    private func note() {
        let artifact = open.firstIndex { $0.mark.tag == "Artifact" }
        let tagged = open.firstIndex { entry in entry.mark.mcid.map { mcid in known.map { $0(entry.form, mcid) } ?? true } ?? false }
        if artifact == nil && tagged == nil {
            untagged += 1
        } else if let artifact, let tagged {
            if artifact > tagged { artifactInTagged += 1 } else { taggedInArtifact += 1 }
        }
    }
}

extension PdfUaChecker {
    func checkContent() throws {
        var inPage: [Int: Set<Int>] = [:]
        var inForm = Set<SequenceInForm>()
        for content in tree?.contents ?? [] {
            if let stream = content.stream {
                inForm.insert(SequenceInForm(stream: stream.number, mcid: content.mcid))
            } else {
                inPage[content.pageIndex, default: []].insert(content.mcid)
            }
        }

        let interpreter = ContentInterpreter(document)
        interpreter.walkPatterns = false
        let fonts = FontUses()
        for page in document.pages {
            try Task.checkCancellation()
            let known: ((PdfStream?, Int) -> Bool)? = tree == nil ? nil : { form, mcid in
                if let form { return inForm.contains(SequenceInForm(stream: form.number, mcid: mcid)) }
                return inPage[page.index]?.contains(mcid) ?? false
            }

            let visitor = PageContent(known)
            interpreter.run(page, visitor)
            let place = PdfAText.pageName(page.index + 1)
            if tree != nil && visitor.untagged > 0 { add("01-005", "7.1", place, PdfUaText.untagged) }
            if visitor.artifactInTagged > 0 { add("01-003", "7.1", place, PdfUaText.artifactInTagged) }
            if visitor.taggedInArtifact > 0 { add("01-004", "7.1", place, PdfUaText.taggedInArtifact) }
            for font in visitor.fonts.fonts {
                let use = visitor.fonts.use(font)
                fonts.note(font, shown: use.shown, noText: use.noText)
            }
        }

        // 7.21.3 and 7.21.4: a font that shows text is embedded (a font used only invisibly is exempt) and maps to Unicode.
        for font in fonts.fonts {
            let use = fonts.use(font)
            let place = PdfAText.fontName(font.baseFont)
            if use.shown && !font.isEmbedded && !font.isType3 { add("31-009", "7.21.4.1", place, PdfUaText.fontNotEmbedded) }
            if use.noText { add("31-027", "7.21.7", place, PdfUaText.fontNoUnicode) }
        }
    }

    // 7.20: no reference XObject, in a page's resources or in the forms below them.
    func checkXObjects() {
        var seen = Set<ObjectIdentifier>()
        var pending: [(resources: PdfDictionary?, place: String)] = []
        for page in document.pages { pending.append((page.resources, PdfAText.pageName(page.index + 1))) }
        while let (resources, place) = pending.popLast(), seen.count < Self.maxEntries {
            guard let xobjects = document.dict(resources, "XObject") else { continue }
            for entry in xobjects.entries.prefix(Self.maxEntries) {
                guard let xobject = document.resolve(entry.value) as? PdfStream, seen.insert(ObjectIdentifier(xobject)).inserted else { continue }
                let subtype = document.name(xobject.dictionary, "Subtype")
                if xobject.dictionary.containsKey("Ref") { add("30-001", "7.20", place, PdfUaText.referenceXObject) }
                if subtype == "Form" { pending.append((document.dict(xobject.dictionary, "Resources"), place)) }
            }
        }
    }
}
