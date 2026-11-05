import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Tables/PdfEncodings.cs: the predefined encodings of ISO 32000-1 Annex D,
// as 256 glyph names indexed by character code; a code the encoding leaves unassigned holds nil.
public enum PdfEncodings {
    public static let standard = parse(EncodingData.standard)

    /// The codes Annex D leaves unused show a bullet, as the table's footnote says.
    public static let winAnsi = parse(EncodingData.winAnsi)

    public static let macRoman = parse(EncodingData.macRoman)

    public static let macExpert = parse(EncodingData.macExpert)

    /// PDFDocEncoding, the one of text strings outside content streams (Annex D.3).
    public static let pdfDoc = parse(EncodingData.pdfDoc)

    /// The built-in encoding of the Symbol font.
    public static let symbol = parse(EncodingData.symbol)

    /// The built-in encoding of ZapfDingbats.
    public static let zapfDingbats = parse(EncodingData.zapfDingbats)

    /// The encoding a font's /Encoding name stands for, or nil for a name that is none of them.
    public static func byName(_ pdfName: String) -> [String?]? {
        switch pdfName {
        case "StandardEncoding": return standard
        case "WinAnsiEncoding": return winAnsi
        case "MacRomanEncoding": return macRoman
        case "MacExpertEncoding": return macExpert
        case "PDFDocEncoding": return pdfDoc
        default: return nil
        }
    }

    /// The first code of `encoding` that shows the glyph, or -1.
    public static func codeOf(_ encoding: [String?], _ glyphName: String) -> Int {
        for code in encoding.indices where encoding[code] == glyphName {
            return code
        }
        return -1
    }

    private static func parse(_ runs: String) -> [String?] {
        var names = [String?](repeating: nil, count: 256)
        var code = 0
        for scalars in runs.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace }) {
            var name = String(String.UnicodeScalarView(scalars))
            if let eq = name.firstIndex(of: "="), eq != name.startIndex {
                guard let start = Int(name[..<eq]) else { preconditionFailure("Bad run in the encoding table.") }
                code = start
                name = String(name[name.index(after: eq)...])
            }
            names[code] = name
            code += 1
        }
        return names
    }
}
