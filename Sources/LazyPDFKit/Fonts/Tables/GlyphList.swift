import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Tables/GlyphList.cs: glyph names and Unicode, by the Adobe Glyph List
// specification: the AGL and the ZapfDingbats list, then the rules for suffixes, ligature components and
// the uniXXXX and uXXXX forms.
public enum GlyphList {
    private static let maxNameLength = 256

    // Entries keep the order of the list: a code point with several names takes the first one.
    private struct Table {
        var names: [String] = []
        var texts: [String: String] = [:]
    }

    private static let agl = readList(GlyphListData.agl)
    private static let zapf = readList(GlyphListData.zapf)
    private static let names = buildNames()
    private static let zapfNames = reverse(zapf, [])

    /// The text a glyph name stands for, or nil when it stands for none (".notdef", "g123", "cid77").
    /// A suffix after the first period is dropped and "f_i" is the concatenation of "f" and "i".
    public static func unicodeOf(_ glyphName: String) -> String? {
        if glyphName.isEmpty || glyphName.utf16.count > maxNameLength {
            return nil
        }
        let scalars = glyphName.unicodeScalars
        var name = scalars
        if let dot = scalars.firstIndex(of: ".") {
            name = String.UnicodeScalarView(scalars[..<dot])
        }
        if name.isEmpty {
            return nil
        }
        if !name.contains("_") {
            return component(String(name))
        }

        var text = ""
        for part in name.split(separator: "_", omittingEmptySubsequences: false) {
            text += component(String(String.UnicodeScalarView(part))) ?? ""
        }
        return text.isEmpty ? nil : text
    }

    /// A glyph name for the character: the AGL name, preferring the one the standard encodings use
    /// (space, not nbspace), else uniXXXX or uXXXXX. ".notdef" for what is not a Unicode scalar value.
    public static func nameOf(_ codePoint: Int) -> String {
        guard let value = UInt32(exactly: codePoint), let scalar = Unicode.Scalar(value) else {
            return ".notdef"
        }
        if let name = names[Int(scalar.value)] {
            return name
        }
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return scalar.value <= 0xFFFF ? "uni" + String(repeating: "0", count: 4 - hex.count) + hex : "u" + hex
    }

    /// The ZapfDingbats glyph name ("a1") of the character, or nil.
    public static func zapfNameOf(_ codePoint: Int) -> String? {
        zapfNames[codePoint]
    }

    private static func component(_ name: String) -> String? {
        if name.isEmpty {
            return nil
        }
        if let text = agl.texts[name] ?? zapf.texts[name] {
            return text
        }
        let units = Array(name.utf16)
        if units.starts(with: [0x75, 0x6E, 0x69]) && units.count > 3 && (units.count - 3) % 4 == 0 {
            var text = String.UnicodeScalarView()
            for start in stride(from: 3, to: units.count, by: 4) {
                guard let unit = hexValue(units[start..<start + 4]), let scalar = Unicode.Scalar(unit) else {
                    return nil
                }
                text.append(scalar)
            }
            return String(text)
        }
        if units[0] == 0x75 && (5...7).contains(units.count), let value = hexValue(units[1...]),
           let scalar = Unicode.Scalar(value) {
            return String(Character(scalar))
        }
        return nil
    }

    // The int parser accepts a sign and spaces, a glyph name must not.
    private static func hexValue(_ units: ArraySlice<UInt16>) -> UInt32? {
        var value: UInt32 = 0
        for unit in units {
            let digit: UInt32
            switch unit {
            case 0x30...0x39: digit = UInt32(unit) - 0x30
            case 0x41...0x46: digit = UInt32(unit) - 0x41 + 10
            case 0x61...0x66: digit = UInt32(unit) - 0x61 + 10
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }

    private static func readList(_ packed: String) -> Table {
        var table = Table()
        for line in TableBlob.inflateText(packed).split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            if parts.count < 2 {
                continue
            }
            var text = String.UnicodeScalarView()
            for part in parts.dropFirst() {
                guard let value = UInt32(part, radix: 16), let scalar = Unicode.Scalar(value) else {
                    preconditionFailure("Bad entry in the glyph list.")
                }
                text.append(scalar)
            }
            let name = String(parts[0])
            if table.texts[name] == nil {
                table.names.append(name)
                table.texts[name] = String(text)
            }
        }
        return table
    }

    private static func buildNames() -> [Int: String] {
        var preferred: [String] = []
        var seen = Set<String>()
        for table in [PdfEncodings.standard, PdfEncodings.winAnsi, PdfEncodings.macRoman,
                      PdfEncodings.macExpert, PdfEncodings.pdfDoc, PdfEncodings.symbol] {
            for case let name? in table where seen.insert(name).inserted {
                preferred.append(name)
            }
        }
        return reverse(agl, preferred)
    }

    // Single-character entries only; a name from preferred wins over the first one in list order.
    private static func reverse(_ list: Table, _ preferred: [String]) -> [Int: String] {
        var map: [Int: String] = [:]
        for name in preferred {
            if let text = list.texts[name], let cp = single(text), map[cp] == nil {
                map[cp] = name
            }
        }
        for name in list.names {
            if let text = list.texts[name], let cp = single(text), map[cp] == nil {
                map[cp] = name
            }
        }
        return map
    }

    private static func single(_ text: String) -> Int? {
        var scalars = text.unicodeScalars.makeIterator()
        guard let first = scalars.next(), scalars.next() == nil else {
            return nil
        }
        return Int(first.value)
    }
}
