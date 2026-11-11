import Foundation

// Twin of windows/LazyPDF.Core/Annotations/AppearanceBuilder.cs: draws the /AP /N stream of an annotation from its
// dictionary, so that a new annotation and an edited one go through the same code. The system renderer ignores /CA and
// /NeedAppearances, so the stream carries opacity, blend mode and everything else itself.

final class AppearanceBuilder {
    static let yellow: [Double] = [1, 1, 0]
    static let red: [Double] = [1, 0, 0]
    static let black: [Double] = [0]

    static let stampMark = "LazyPDFText"

    let document: PdfDocument
    private let fonts: FontSource?
    private var embedderMade: PdfFontEmbedder?
    var undrawn: Set<Int> = []

    init(_ document: PdfDocument, _ fonts: FontSource?) {
        self.document = document
        self.fonts = fonts
    }

    var embedder: PdfFontEmbedder {
        if let made = embedderMade { return made }
        let made = PdfFontEmbedder(document, fonts)
        embedderMade = made
        return made
    }

    /// The characters no font could draw since the last call, once each in code point order; clears them.
    func takeUndrawn() -> String {
        let text = String(String.UnicodeScalarView(undrawn.sorted().compactMap { Unicode.Scalar(UInt32($0)) }))
        undrawn = []
        return text
    }

    /// True for the subtypes this builder can draw.
    static func canDraw(_ type: AnnotationType) -> Bool {
        type != .other && type != .popup && type != .widget
    }

    /// Replaces the annotation's /AP with a new stream drawn from its other keys. False, and nothing touched, when the
    /// subtype has no appearance of ours or the rectangle has no area.
    func apply(_ dictionary: PdfDictionary) throws -> Bool {
        guard let a = PdfAnnotations.parse(document, dictionary, nil), !a.rect.isEmpty else { return false }
        // Artwork that is not our text box (an image, a foreign stamp) would be lost to a redraw.
        if a.type == .stamp, let art = document.stream(document.dict(dictionary, "AP"), "N"), !art.dictionary.containsKey(Self.stampMark) {
            return false
        }
        guard let canvas = try draw(a) else { return false }
        let stream = canvas.toStream()
        if a.type == .stamp { stream.dictionary[Self.stampMark] = PdfBoolean(true) }
        let ap = PdfDictionary()
        ap["N"] = try document.add(stream)
        dictionary["AP"] = ap
        return true
    }

    private func draw(_ a: PdfAnnotation) throws -> AppearanceCanvas? {
        switch a.type {
        case .highlight: return highlight(a)
        case .underline: return underline(a, strike: false)
        case .strikeOut: return underline(a, strike: true)
        case .squiggly: return squiggly(a)
        case .square: return shape(a, ellipse: false)
        case .circle: return shape(a, ellipse: true)
        case .line: return line(a)
        case .polyLine: return polyLine(a)
        case .polygon: return polygon(a)
        case .ink: return ink(a)
        case .freeText: return try freeText(a)
        case .stamp: return try stamp(a)
        case .text: return note(a)
        case .caret: return caret(a)
        case .fileAttachment: return attachment(a)
        case .redact: return redact(a)
        case .link: return link(a)
        default: return nil
        }
    }

    func canvas(_ a: PdfAnnotation) -> AppearanceCanvas { AppearanceCanvas(document, a.rect) }

    static func paints(_ color: [Double]?) -> Bool { !(color?.isEmpty ?? true) }
}
