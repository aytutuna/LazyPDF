import Foundation

// Twin of windows/LazyPDF.Core/Office/Layout/LayoutFonts.cs.

/// One font file at one style, parsed for measuring.
final class FontFace {
    private var advances: [Int: Double] = [:]

    init(family: String, style: FontStyles, font: TrueTypeFont) {
        self.family = family
        self.style = style
        self.font = font
        ascent = Double(font.ascent + font.lineGap) / Double(font.unitsPerEm)
        descent = Double(-font.descent) / Double(font.unitsPerEm)
    }

    let family: String
    let style: FontStyles
    let font: TrueTypeFont

    /// In em, the line gap included so that a single-spaced line is ascent plus descent.
    let ascent: Double
    let descent: Double

    func covers(_ codePoint: Int) -> Bool { font.glyphForCodePoint(codePoint) != 0 }

    /// In em; no kerning.
    func advance(_ codePoint: Int) -> Double {
        if let known = advances[codePoint] { return known }
        let advance = Double(font.getAdvance(font.glyphForCodePoint(codePoint))) / Double(font.unitsPerEm)
        advances[codePoint] = advance
        return advance
    }
}

/// The faces a document asks for, and per character the face that has a glyph.
final class LayoutFonts {
    // Tried in this order when the family of a run has no glyph for a character.
    private static let fallbacks = [
        "Segoe UI", "Segoe UI Symbol", "Microsoft YaHei", "Yu Gothic", "Malgun Gothic", "Arial Unicode MS", "PingFang SC", "Hiragino Sans",
        "Apple SD Gothic Neo", "Liberation Sans",
    ]

    private struct FaceKey: Hashable {
        let family: String
        let style: Int
    }

    private struct FileKey: Hashable {
        let address: Int
        let index: Int
        let style: Int
    }

    private struct ChoiceKey: Hashable {
        let face: ObjectIdentifier
        let codePoint: Int
    }

    private let source: FontSource?
    private var faces: [FaceKey: FontFace?] = [:]
    private var byFile: [FileKey: FontFace?] = [:]
    private var chosen: [ChoiceKey: FontFace?] = [:]

    init(_ source: FontSource?) {
        self.source = source
    }

    /// Code points no face could draw.
    private(set) var missing: Set<Int> = []

    func find(_ family: String, _ style: FontStyles) -> FontFace? {
        let key = FaceKey(family: family, style: style.rawValue)
        if let known = faces[key] { return known }
        var face: FontFace?
        if let file = source?.find(family, style) {
            // Names that resolve to the same file share one face (and one embedded subset); the first name stays on it.
            // The data array by storage address: a source that hands the same bytes back is the same file.
            let address = file.data.withUnsafeBufferPointer { $0.baseAddress.map { Int(bitPattern: $0) } }
            let fileKey = address.map { FileKey(address: $0, index: file.collectionIndex, style: style.rawValue) }
            if let fileKey, let known = byFile[fileKey] {
                face = known
            } else {
                if let font = TrueTypeFont.tryParse(file.data, file.collectionIndex), font.unitsPerEm > 0 {
                    face = FontFace(family: family, style: style, font: font)
                }
                if let fileKey { byFile[fileKey] = .some(face) }
            }
        }
        faces[key] = .some(face)
        return face
    }

    /// The face to draw `codePoint` with: `primary` if it has the glyph, else the first fallback that has.
    func choose(_ primary: FontFace, _ codePoint: Int) -> FontFace {
        let key = ChoiceKey(face: ObjectIdentifier(primary), codePoint: codePoint)
        if let known = chosen[key] { return known ?? primary }
        var pick: FontFace? = primary.covers(codePoint) ? primary : nil
        if pick == nil {
            for family in Self.fallbacks {
                if let face = find(family, primary.style), face.covers(codePoint) {
                    pick = face
                    break
                }
            }
        }
        if pick == nil { missing.insert(codePoint) }
        chosen[key] = .some(pick)
        return pick ?? primary
    }
}
