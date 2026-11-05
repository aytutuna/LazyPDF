import Foundation

// Twin of windows/LazyPDF.Core/Ocr/OcrTriage.cs: decides which pages OCR is for. One pass of the content interpreter
// over each page.

/// What a page holds, as far as OCR is concerned.
public enum OcrPageKind: Int, Comparable {
    /// Nothing is drawn.
    case blank
    /// Paths or small pictures and no text: outlined text, a drawing.
    case drawing
    /// A picture covers most of the page and any text on it is a stamp or a number.
    case picture
    /// The page has the layer `PdfOcrLayer` wrote, whatever else it shows.
    case ownLayer
    /// The only text is invisible and not ours: an earlier OCR by another tool.
    case foreignLayer
    /// The page has text a person can see.
    case text

    public static func < (a: OcrPageKind, b: OcrPageKind) -> Bool { a.rawValue < b.rawValue }
}

public enum OcrTriage {
    /// A picture this share of the page, or more, makes it a scan.
    public static let pictureShare = 0.6

    /// Visible text covering less than this share of a page with a picture on it does not count as text.
    public static let sparseTextShare = 0.02

    public static func classify(_ document: PdfDocument, _ page: PdfPage) -> OcrPageKind {
        classify(document, page, ContentInterpreter(document))
    }

    public static func classifyAll(_ document: PdfDocument) -> [OcrPageKind] {
        let interpreter = ContentInterpreter(document)
        return document.pages.map { classify(document, $0, interpreter) }
    }

    /// Whether a page of this kind is to be read: pictures and drawings always, an own layer when it is to be replaced,
    /// text and foreign layers only when forced, blank pages only when forced.
    public static func needsOcr(_ kind: OcrPageKind, _ replaceOwnLayer: Bool, _ force: Bool) -> Bool {
        switch kind {
        case .picture, .drawing: return true
        case .ownLayer: return replaceOwnLayer
        default: return force
        }
    }

    static func classify(_ document: PdfDocument, _ page: PdfPage, _ interpreter: ContentInterpreter) -> OcrPageKind {
        let survey = Survey(page.cropBox)
        interpreter.run(page, survey)
        let area = page.cropBox.width * page.cropBox.height
        let picture = area > 0 && survey.pictureArea / area >= pictureShare
        let visibleText = survey.visible > 0 && !(picture && survey.textArea / area < sparseTextShare)
        if PdfOcrLayer.has(document, page) { return .ownLayer }
        if visibleText { return .text }
        if survey.invisible > 0 { return .foreignLayer }
        if picture { return .picture }
        return survey.marks > 0 ? .drawing : .blank
    }

    private final class Survey: ContentVisitor {
        let crop: PdfRect
        var visible = 0
        var invisible = 0
        var marks = 0
        var textArea = 0.0
        var pictureArea = 0.0

        init(_ crop: PdfRect) {
            self.crop = crop
        }

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            let mode = context.state.renderMode
            if mode == 3 {
                invisible += 1
                return
            }
            if mode == 7 { return }
            if let text = glyph.unicode, text.utf16.allSatisfy({ $0.isWhiteSpace }) { return }
            visible += 1
            let box = glyph.bounds.intersect(crop)
            if !box.isEmpty { textArea += box.width * box.height }
        }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            marks += 1
            let box = image.bounds.intersect(crop)
            if !box.isEmpty { pictureArea += box.width * box.height }
        }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            if path.fill || path.stroke { marks += 1 }
        }

        override func paintShading(_ context: ContentContext, _ shading: ShadingInfo) {
            marks += 1
        }
    }
}
