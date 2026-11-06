import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportXml.cs: what the Office writers share, escaping, number text and the limit
// on the length of a file built as one string. From Lazy Scan's DocxWriter.cs (EscapeXml): characters XML cannot hold
// are left out.

/// The part of `StringBuilder` the writers use: text that appends in place and knows its length in UTF-16 units.
final class ExportBuilder {
    private(set) var text: String
    private(set) var length: Int

    init(_ start: String = "") {
        text = start
        length = start.utf16.count
    }

    @discardableResult
    func append(_ more: String) -> ExportBuilder {
        text += more
        length += more.utf16.count
        return self
    }

    @discardableResult
    func append(_ c: Character, _ count: Int = 1) -> ExportBuilder {
        for _ in 0..<max(0, count) {
            text.append(c)
            length += c.utf16.count
        }
        return self
    }
}

enum ExportXml {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static let emuPerPoint: Int = 12700

    // A .NET string holds 1,073,741,791 characters. A writer that builds its file as one string checks the length as it goes and
    // refuses a document that would pass this, so the failure is a PdfReadException and not an OutOfMemoryException at ToString.
    static let maxOutputChars = 1 << 29

    static func checkLength(_ sb: ExportBuilder, _ coming: Int = 0, _ limit: Int = maxOutputChars) throws {
        if sb.length + coming > limit { throw PdfReadException(.unsupported, ExportText.tooLarge) }
    }

    // The characters a picture adds where its bytes are written out at every occurrence.
    static func encoded(_ block: ExportBlock, _ hex: Bool) -> Int {
        guard let picture = block as? ExportPicture else { return 0 }
        let count = picture.image.data.count
        return hex ? 2 * count : (count + 2) / 3 * 4
    }

    static func escape(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case UInt8(ascii: "&"): out.append(contentsOf: Array("&amp;".utf8))
            case UInt8(ascii: "<"): out.append(contentsOf: Array("&lt;".utf8))
            case UInt8(ascii: ">"): out.append(contentsOf: Array("&gt;".utf8))
            case UInt8(ascii: "\""): out.append(contentsOf: Array("&quot;".utf8))
            case 9, 10, 13: out.append(b)
            case 0..<0x20: break
            case 0xEF where i + 2 < bytes.count && bytes[i + 1] == 0xBF && bytes[i + 2] >= 0xBE:
                // U+FFFE and U+FFFF
                i += 2
            default: out.append(b)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func i(_ value: Int) -> String { String(value) }

    static func d(_ value: Double) -> String { InvariantNumbers.twoDecimals(value) }

    static func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }

    static func emu(_ points: Double) -> Int {
        // Math.Clamp(Math.Round(...), 1, 1e11)
        let rounded = (points * Double(emuPerPoint)).rounded(.toNearestOrEven)
        return rounded.isNaN ? 0 : Int(min(max(rounded, 1), 1e11))
    }
}
