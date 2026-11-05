import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Tables/ToUnicodeCMap.cs: writes the body of a ToUnicode CMap stream
// (ISO 32000-1 9.10.3).
public enum ToUnicodeCMap {
    /// Where the C# throws ArgumentOutOfRangeException. The codes can come from a file's font, so it is
    /// thrown and not a precondition.
    public struct OutOfRange: Error {
        public let message: String
    }

    // A bfchar or bfrange section holds at most 100 entries (Adobe Technical Note 5014).
    private static let sectionSize = 100

    private typealias Run = (lo: UInt32, hi: UInt32, text: [UInt16])

    /// The stream data for a font whose character codes are `codeBytes` bytes (1 to 4) long. Codes in a
    /// row that map to characters in a row become one bfrange. A code given twice keeps its last text;
    /// empty text is left out. Throws `OutOfRange` for a code that does not fit the length.
    public static func write(_ map: [(key: Int, value: String)], codeBytes: Int = 2) throws -> [UInt8] {
        if codeBytes < 1 || codeBytes > 4 {
            throw OutOfRange(message: "codeBytes must be 1 to 4.")
        }
        let limit = UInt64(1) << UInt64(8 * codeBytes)
        var texts: [UInt32: [UInt16]] = [:]
        for (code, text) in map {
            guard let code32 = Int32(exactly: code), UInt64(UInt32(bitPattern: code32)) < limit else {
                throw OutOfRange(message: "Code \(code) does not fit \(codeBytes) bytes.")
            }
            if !text.isEmpty {
                texts[UInt32(bitPattern: code32)] = Array(text.utf16)
            }
        }

        var ranges: [Run] = []
        for code in texts.keys.sorted() {
            let text = texts[code] ?? []
            if let last = ranges.last, continues(last, code, text) {
                ranges[ranges.count - 1].hi = code
            } else {
                ranges.append((code, code, text))
            }
        }

        let width = 2 * codeBytes
        var out = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
        out += "/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def\n"
        out += "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
        out += "1 begincodespacerange\n<" + String(repeating: "0", count: width) + "> <" + String(repeating: "F", count: width)
        out += ">\nendcodespacerange\n"

        let singles = ranges.filter { $0.lo == $0.hi }
        let spans = ranges.filter { $0.lo != $0.hi }
        for start in stride(from: 0, to: spans.count, by: sectionSize) {
            let section = spans[start..<min(start + sectionSize, spans.count)]
            out += "\(section.count) beginbfrange\n"
            for r in section {
                out += "<\(hex(r.lo, width))> <\(hex(r.hi, width))> <\(utf16Hex(r.text))>\n"
            }
            out += "endbfrange\n"
        }
        for start in stride(from: 0, to: singles.count, by: sectionSize) {
            let section = singles[start..<min(start + sectionSize, singles.count)]
            out += "\(section.count) beginbfchar\n"
            for r in section {
                out += "<\(hex(r.lo, width))> <\(utf16Hex(r.text))>\n"
            }
            out += "endbfchar\n"
        }
        out += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return Array(out.utf8)
    }

    // The next code extends the range when its text is the range's last text plus one in the final UTF-16 unit.
    // Neither the code's nor the unit's low byte may wrap inside the range: readers differ on what a carry means.
    private static func continues(_ range: Run, _ code: UInt32, _ text: [UInt16]) -> Bool {
        if code != range.hi &+ 1 || (code ^ range.lo) > 0xFF || text.count != range.text.count {
            return false
        }
        let span = Int(code - range.lo)
        guard let first = range.text.last, text.dropLast().elementsEqual(range.text.dropLast()) else {
            return false
        }
        return text.last == UInt16(truncatingIfNeeded: Int(first) + span) && Int(first & 0xFF) + span <= 0xFF
    }

    private static func hex(_ value: UInt32, _ width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func utf16Hex(_ text: [UInt16]) -> String {
        text.map { hex(UInt32($0), 4) }.joined()
    }
}
