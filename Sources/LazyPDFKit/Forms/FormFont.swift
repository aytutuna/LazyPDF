import Foundation

// Twin of windows/LazyPDF.Core/Forms/FormFont.cs: a font a field's text is set in: one of the form's /DR fonts, or one
// added for text those cannot show.

final class FormFont {
    private let added: PdfDrawFont?
    private let codes: [Int: (code: Int, width: Double)]?

    private init(_ name: String, _ reference: PdfReference, _ ascent: Double, _ descent: Double, _ added: PdfDrawFont?, _ codes: [Int: (code: Int, width: Double)]?) {
        self.name = name
        self.reference = reference
        self.ascent = ascent
        self.descent = descent
        self.added = added
        self.codes = codes
    }

    let name: String
    let reference: PdfReference

    /// In em; the descent is negative.
    let ascent: Double
    let descent: Double

    func lineHeight(_ size: Double) -> Double { (ascent - descent) * size }

    /// A simple font of the form's resources, or nil for one the text cannot be encoded for: Type0 and Type3 fonts. The
    /// characters it can show are those its encoding gives a Unicode value.
    static func fromResource(_ document: PdfDocument, _ name: String, _ resources: PdfDictionary) throws -> FormFont? {
        let fonts = document.dict(resources, "Font")
        guard let fonts, let entry = fonts[name], let dictionary = document.resolve(entry) as? PdfDictionary else { return nil }
        var reference = entry as? PdfReference
        if reference == nil {
            let made = try document.add(dictionary)
            reference = made
            fonts[name] = made
        }
        guard let reference else { return nil }
        let font = PdfFont.get(document, dictionary)
        if font.isComposite || font.isType3 { return nil }
        var codes: [Int: (code: Int, width: Double)] = [:]
        for code in 32..<256 {
            let c = font.read([UInt8(code)][...]).character
            let scalars = c.unicode?.unicodeScalars
            // Half of a surrogate pair reads as U+FFFD (PORTING, known differences); the C# drops that entry.
            if let scalars, scalars.count == 1, let rune = scalars.first, rune.value != 0xFFFD, codes[Int(rune.value)] == nil {
                codes[Int(rune.value)] = (code, c.width)
            }
        }
        if codes[0xA0] == nil, let space = codes[32] { codes[0xA0] = space }
        let ascent = font.ascent > 0 ? font.ascent / 1000 : 0.8
        let descent = font.descent < 0 ? font.descent / 1000 : -0.2
        return FormFont(name, reference, ascent, descent, nil, codes)
    }

    static func fromAdded(_ name: String, _ font: PdfDrawFont) -> FormFont {
        FormFont(name, font.reference, font.ascent, font.descent, font, nil)
    }

    func canShow(_ text: String) -> Bool {
        for rune in text.unicodeScalars {
            let value = Int(rune.value)
            if value < 0x20 { continue }
            if let codes {
                if codes[value] == nil { return false }
            } else if let added, added.missing.contains(value) {
                return false
            }
        }
        return true
    }

    func encode(_ text: String) -> [UInt8] {
        if let added { return added.encode(text) }
        var bytes: [UInt8] = []
        for rune in text.unicodeScalars where rune.value >= 0x20 {
            if let c = codes?[Int(rune.value)] { bytes.append(UInt8(truncatingIfNeeded: c.code)) }
        }
        return bytes
    }

    func width(_ text: String, _ size: Double) -> Double {
        if let added { return added.width(text, size) }
        var units = 0.0
        for rune in text.unicodeScalars where rune.value >= 0x20 {
            if let c = codes?[Int(rune.value)] { units += c.width }
        }
        return units * size / 1000
    }

    /// Lines no wider than `maxWidth`: broken at spaces and newlines, a word wider than the box at the character.
    func wrap(_ text: String, _ size: Double, _ maxWidth: Double) -> [String] {
        var lines: [String] = []
        for paragraph in Self.paragraphs(text) {
            var line = String.UnicodeScalarView()
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let wordText = String(String.UnicodeScalarView(word))
                let joined = line.isEmpty ? wordText : String(line) + " " + wordText
                if width(joined, size) <= maxWidth {
                    line = joined.unicodeScalars
                    continue
                }
                if !line.isEmpty {
                    lines.append(String(line))
                    line = String.UnicodeScalarView()
                }
                for rune in word {
                    if !line.isEmpty && width(String(line) + String(rune), size) > maxWidth {
                        lines.append(String(line))
                        line = String.UnicodeScalarView()
                    }
                    line.append(rune)
                }
            }
            lines.append(String(line))
        }
        return lines
    }

    // string.ReplaceLineEndings("\n").Split('\n'): CR LF, CR, LF, FF, NEL, LS and PS all end a paragraph.
    private static func paragraphs(_ text: String) -> [[Unicode.Scalar]] {
        var result: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 10 && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = v == 13
            if v == 10 || v == 13 || v == 12 || v == 0x85 || v == 0x2028 || v == 0x2029 {
                result.append(current)
                current = []
            } else {
                current.append(scalar)
            }
        }
        result.append(current)
        return result
    }

    /// The family and style to look a replacement up by: the form font's own name, without the PostScript decoration.
    static func familyOf(_ document: PdfDocument, _ resources: PdfDictionary, _ name: String) -> (family: String, style: FontStyles) {
        guard let fonts = document.dict(resources, "Font"), let dictionary = document.resolve(fonts[name]) as? PdfDictionary else {
            return ("Helvetica", .regular)
        }
        let font = PdfFont.get(document, dictionary)
        var family = Array(font.name.unicodeScalars.prefix { $0 != "-" && $0 != "," })
        for suffix in ["PSMT", "MT", "PS"] {
            let tail = Array(suffix.unicodeScalars)
            if family.count > tail.count && Array(family.suffix(tail.count)) == tail {
                family.removeLast(tail.count)
                break
            }
        }
        var style = FontStyles.regular
        if font.isBold { style.insert(.bold) }
        if font.isItalic { style.insert(.italic) }
        return (family.isEmpty ? "Helvetica" : String(String.UnicodeScalarView(family)), style)
    }
}
