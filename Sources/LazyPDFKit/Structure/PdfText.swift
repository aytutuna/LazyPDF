import Foundation

// Twin of windows/LazyPDF.Core/Structure/PdfText.cs: text strings (ISO 32000-1 7.9.2.2): PDFDocEncoding, UTF-16BE
// with a byte order mark, and UTF-8 with one (PDF 2.0). Every title, author, label and description in the file is one.
//
// Structure layer decisions: the C# parses XMP with System.Xml.Linq and reads dates with DateTimeOffset. Here
// XmlTree.swift, XmlReader.swift and XmlNameTables.swift are a small reader and writer for the XMP packet, and
// DateTimeOffset.swift holds a DateTimeOffset of its own. The departures from the C# are listed under "Known differences"
// in PORTING.md: XMP dates are read in the ISO 8601 forms only, ViewerSettings reads page mode and layout by name only,
// XML nests at most 1000 levels, Outline.write finds a changed destination by value, and the XMP writer ends its lines
// with LF.

public enum PdfText {
    private struct Tables {
        var decode: [String] = []
        var encode: [UInt16: UInt8] = [:]
    }

    private static let tables = buildTables()

    /// The text of the bytes; a language escape (7.9.2.2) is dropped.
    public static func decode(_ bytes: [UInt8]) -> String {
        let text: String
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            text = utf16(bytes.dropFirst(2), bigEndian: true)
        } else if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
            text = utf16(bytes.dropFirst(2), bigEndian: false)
        } else if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            text = String(decoding: bytes.dropFirst(3), as: UTF8.self)
        } else {
            let table = tables.decode
            var result = ""
            for b in bytes { result += table[Int(b)] }
            return result
        }
        return stripLanguage(text)
    }

    /// The smallest correct form: PDFDocEncoding when every character is in it, UTF-16BE with a byte order mark otherwise.
    public static func encode(_ text: String) -> [UInt8] {
        let table = tables.encode
        var bytes: [UInt8] = []
        for unit in text.utf16 {
            guard let b = table[unit] else {
                var wide: [UInt8] = [0xFE, 0xFF]
                for u in text.utf16 {
                    wide.append(UInt8(u >> 8))
                    wide.append(UInt8(u & 0xFF))
                }
                return wide
            }
            bytes.append(b)
        }
        return bytes
    }

    /// The /F string of a file specification, which is bytes and not a text string: ASCII, with _ for the rest (/UF has the real name).
    static func toFileName(_ name: String) -> PdfString {
        PdfString(bytes: name.utf16.map { $0 >= 0x20 && $0 <= 0x7E ? UInt8($0) : 0x5F }, isHex: false)
    }

    /// A string object for the text, in hex when it holds bytes a literal would have to escape.
    public static func toObject(_ text: String) -> PdfString {
        let bytes = encode(text)
        return PdfString(bytes: bytes, isHex: bytes.contains { $0 < 0x20 || $0 >= 0x7F })
    }

    /// The text a value stands for: a string, or a stream's decoded data (JavaScript may be either). Nil for anything else.
    public static func read(_ document: PdfDocument, _ value: PdfObject?) -> String? {
        switch document.resolve(value) {
        case let s as PdfString: return decode(s.bytes)
        case let s as PdfStream: return tryData(document, s)
        default: return nil
        }
    }

    public static func read(_ document: PdfDocument, _ dictionary: PdfDictionary?, _ key: String) -> String? {
        read(document, dictionary?[key])
    }

    private static func tryData(_ document: PdfDocument, _ stream: PdfStream) -> String? {
        do {
            return decode(try document.data(stream))
        } catch {
            return nil
        }
    }

    // An odd last byte and a lone surrogate read as U+FFFD, as Encoding.BigEndianUnicode and Encoding.Unicode do.
    private static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2 + 1)
        var pair: [UInt8] = []
        for b in bytes {
            pair.append(b)
            if pair.count == 2 {
                units.append(bigEndian ? UInt16(pair[0]) << 8 | UInt16(pair[1]) : UInt16(pair[1]) << 8 | UInt16(pair[0]))
                pair.removeAll(keepingCapacity: true)
            }
        }
        if !pair.isEmpty { units.append(0xFFFD) }
        return String(decoding: units, as: UTF16.self)
    }

    private static func stripLanguage(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let escape: Unicode.Scalar = "\u{1B}"
        guard var start = scalars.firstIndex(of: escape) else { return text }
        var result = String.UnicodeScalarView()
        var at = 0
        while true {
            result.append(contentsOf: scalars[at..<start])
            guard let end = scalars[(start + 1)...].firstIndex(of: escape) else { return String(result) }
            at = end + 1
            guard let next = scalars[at...].firstIndex(of: escape) else { break }
            start = next
        }
        result.append(contentsOf: scalars[at...])
        return String(result)
    }

    private static func buildTables() -> Tables {
        var tables = Tables()
        let names = PdfEncodings.pdfDoc
        for code in 0..<256 {
            // Codes the encoding leaves out read as Latin-1, which is what most writers meant.
            let name = code < names.count ? names[code] : nil
            let text = name.flatMap { GlyphList.unicodeOf($0) }
            let single = text.map { $0.utf16.count == 1 } ?? false
            let decoded = single ? (text ?? "") : String(Unicode.Scalar(UInt8(code)))
            tables.decode.append(decoded)
            if single || code == 9 || code == 10 || code == 13, let unit = decoded.utf16.first, tables.encode[unit] == nil {
                tables.encode[unit] = UInt8(code)
            }
        }
        return tables
    }
}
