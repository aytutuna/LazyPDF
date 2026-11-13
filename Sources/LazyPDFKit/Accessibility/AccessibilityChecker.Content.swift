import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/AccessibilityChecker.Content.cs: what a page's content says about itself,
// found in one run of the interpreter.

private struct FormSequence: Hashable {
    let stream: Int
    let mcid: Int
}

private final class PageContent: ContentVisitor {
    private let known: (PdfStream?, Int) -> Bool
    private var open: [(mark: MarkedContent, form: PdfStream?)] = []

    private(set) var glyphs = 0
    private(set) var images = 0
    private(set) var loose = 0
    private(set) var fontsWithoutText: [String: Int] = [:]

    init(_ known: @escaping (PdfStream?, Int) -> Bool) {
        self.known = known
        super.init()
    }

    override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
        if glyph.character.isSpace { return }
        glyphs += 1
        // 7.21.7 of ISO 14289-1: every character maps to Unicode.
        if (glyph.unicode ?? "").isEmpty {
            fontsWithoutText[glyph.font.name, default: 0] += 1
        }
        note(context)
    }

    override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
        images += 1
        note(context)
    }

    override func paintPath(_ context: ContentContext, _ path: PathInfo) {
        if path.fill || path.stroke { note(context) }
    }

    override func paintShading(_ context: ContentContext, _ shading: ShadingInfo) {
        note(context)
    }

    // A sequence is numbered in the stream that holds it, so each is kept with its form.
    override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
        open.append((marked, context.forms.last))
    }

    override func endMarked(_ context: ContentContext, _ marked: MarkedContent) {
        _ = open.popLast()
    }

    // 7.1 of ISO 14289-1: everything drawn is in the tags or an artifact.
    private func note(_ context: ContentContext) {
        if context.marked.contains(where: { $0.tag == "Artifact" }) { return }
        if !open.contains(where: { entry in entry.mark.mcid.map { known(entry.form, $0) } ?? false }) { loose += 1 }
    }
}

extension AccessibilityChecker {
    /// The tagged-content rule alone, for the PDF/A level A checks.
    static func taggedContent(_ document: PdfDocument, _ tree: StructureTree) throws -> AccessibilityItem {
        try readContent(document, tree).taggedContent
    }

    static func readContent(_ document: PdfDocument, _ tree: StructureTree?) throws -> (searchable: AccessibilityItem, encoding: AccessibilityItem, taggedContent: AccessibilityItem) {
        var inPage: [Int: Set<Int>] = [:]
        var inForm = Set<FormSequence>()
        for content in tree?.contents ?? [] {
            if let stream = content.stream {
                inForm.insert(FormSequence(stream: stream.number, mcid: content.mcid))
            } else {
                inPage[content.pageIndex, default: []].insert(content.mcid)
            }
        }

        let interpreter = ContentInterpreter(document)
        interpreter.walkPatterns = false
        let imageOnly = Found()
        let fonts = Found()
        let loose = Found()
        var seenFonts = Set<String>()
        for page in document.pages {
            try Task.checkCancellation()
            // Without a tree every sequence counts as known: the tagged rule is then a person's to judge.
            let known: (PdfStream?, Int) -> Bool = { form, mcid in
                if tree == nil { return true }
                if let form { return inForm.contains(FormSequence(stream: form.number, mcid: mcid)) }
                return inPage[page.index]?.contains(mcid) ?? false
            }

            let visitor = PageContent(known)
            interpreter.run(page, visitor)
            if visitor.images > 0 && visitor.glyphs == 0 { imageOnly.add(page.index, page.reference) }
            for font in visitor.fontsWithoutText.keys {
                if seenFonts.insert(font).inserted { fonts.add(page.index, page.reference) }
            }
            if visitor.loose > 0 { loose.add(page.index, page.reference) }
        }

        return (
            imageOnly.count == 0 ? pass(.searchable) : fail(.searchable, imageOnly),
            fonts.count == 0 ? pass(.encoding) : fail(.encoding, fonts),
            tree == nil ? noTags(.taggedContent) : loose.count == 0 ? pass(.taggedContent) : fail(.taggedContent, loose))
    }
}
