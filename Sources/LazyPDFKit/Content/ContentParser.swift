import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentParser.cs: content stream bytes to operations (ISO 32000-1 7.8.2,
// Annex A). Nothing in the data stops the parse: unknown operators come back as they are, stray delimiters and
// unclosed arrays are made up for, and the work is linear in the length.

public enum ContentParser {
    // Operands kept for one operator; the rest are dropped. Real operators take at most a few dozen.
    private static let maxOperands = 512
    private static let maxDepth = 64
    private static let maxOperatorLength = 32

    private static let known: Set<String> = [
        "b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP",
        "EI", "EMC", "ET", "EX", "f", "F", "f*", "G", "g", "gs", "h", "i", "ID", "j", "J", "K", "k", "l", "m", "M",
        "MP", "n", "q", "Q", "re", "RG", "rg", "ri", "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td",
        "TD", "Tf", "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz", "v", "w", "W", "W*", "y", "'", "\"",
    ]

    public static func parse(_ data: [UInt8]) -> [ContentOperation] {
        var scanner = Scanner(data)
        // Int32.max operations cannot be reached, so the throw is not.
        return (try? scanner.run(Int(Int32.max))) ?? []
    }

    /// As above; more than `maxOperations` operations is a `PdfReadException`.
    static func parse(_ data: [UInt8], _ maxOperations: Int) throws -> [ContentOperation] {
        var scanner = Scanner(data)
        return try scanner.run(maxOperations)
    }

    private static func isWhite(_ c: UInt8) -> Bool {
        c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32
    }

    private static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    private static func isRegular(_ c: UInt8) -> Bool { !isWhite(c) && !isDelimiter(c) }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func hex(_ c: UInt8) -> Int {
        switch c {
        case 0x30...0x39: return Int(c) - 0x30
        case 0x41...0x46: return Int(c) - 0x41 + 10
        case 0x61...0x66: return Int(c) - 0x61 + 10
        default: return -1
        }
    }

    private struct Scanner {
        private let d: [UInt8]
        private var p = 0

        init(_ data: [UInt8]) {
            d = data
        }

        mutating func run(_ maxOperations: Int) throws -> [ContentOperation] {
            var ops: [ContentOperation] = []
            var operands: [PdfObject] = []
            var opStart = 0
            while true {
                skipSpace()
                if p >= d.count { break }
                if ops.count > maxOperations { throw PdfReadException.damaged("Too many operations in a content stream.") }
                if operands.isEmpty { opStart = p }
                if let value = readValue(0) {
                    if operands.count < ContentParser.maxOperands { operands.append(value) }
                    continue
                }
                if ContentParser.isDelimiter(d[p]) {
                    p += 1
                    continue
                }
                let name = readWord()
                if name == "BI" {
                    let image = readInlineImage()
                    ops.append(ContentOperation("BI", [], opStart, p, image))
                } else {
                    ops.append(ContentOperation(name, operands, opStart, p))
                }
                operands = []
            }
            return ops
        }

        private func at(_ position: Int) -> UInt8? { position < d.count ? d[position] : nil }

        private func string(_ from: Int, _ to: Int) -> String {
            var i = from
            while i < to {
                if d[i] >= 0x80 { return Latin1.string(Array(d[from..<to])) }
                i += 1
            }
            return String(decoding: d[from..<to], as: UTF8.self)
        }

        private mutating func skipSpace() {
            while p < d.count {
                let c = d[p]
                if ContentParser.isWhite(c) {
                    p += 1
                } else if c == 0x25 {
                    while p < d.count && d[p] != 10 && d[p] != 13 { p += 1 }
                } else {
                    return
                }
            }
        }

        /// The operand at the position, or nil (nothing consumed) at a keyword, a closing delimiter or the end.
        private mutating func readValue(_ depth: Int) -> PdfObject? {
            skipSpace()
            if p >= d.count { return nil }
            let c = d[p]
            switch c {
            case 0x2F: return readName()
            case 0x28: return readLiteral()
            case 0x3C: return at(p + 1) == 0x3C ? readDictionary(depth) : readHex()
            case 0x5B: return readArray(depth)
            default: break
            }
            if ContentParser.isDigit(c) || c == 0x2B || c == 0x2D || c == 0x2E { return readNumber() }
            if ContentParser.isDelimiter(c) { return nil }
            var end = p
            while end < d.count && ContentParser.isRegular(d[end]) { end += 1 }
            let word = d[p..<end]
            var literal: PdfObject?
            if word.elementsEqual("true".utf8) {
                literal = PdfBoolean(true)
            } else if word.elementsEqual("false".utf8) {
                literal = PdfBoolean(false)
            } else if word.elementsEqual("null".utf8) {
                literal = PdfNull.instance
            }
            if literal != nil { p = end }
            return literal
        }

        // "--5" is -5, "1.2.3" is 1.2 and then .3, "-" and "." are 0.
        private mutating func readNumber() -> PdfNumber {
            let start = p
            let negative = d[p] == 0x2D
            while p < d.count && (d[p] == 0x2B || d[p] == 0x2D) { p += 1 }
            let plainSign = p - start <= 1
            let digitsStart = p
            while p < d.count && ContentParser.isDigit(d[p]) { p += 1 }
            let whole = p - digitsStart
            var fraction = 0
            if p < d.count && d[p] == 0x2E {
                p += 1
                let from = p
                while p < d.count && ContentParser.isDigit(d[p]) { p += 1 }
                fraction = p - from
            }
            if whole == 0 && fraction == 0 { return PdfNumber("0") }
            if plainSign { return PdfNumber(string(start, p)) }
            return PdfNumber((negative ? "-" : "") + string(digitsStart, p))
        }

        private mutating func readWord() -> String {
            let start = p
            while p < d.count && ContentParser.isRegular(d[p]) { p += 1 }
            let length = Swift.min(p - start, ContentParser.maxOperatorLength)
            return string(start, start + length)
        }

        private mutating func readName() -> PdfName {
            p += 1
            let start = p
            var escaped = false
            while p < d.count && ContentParser.isRegular(d[p]) {
                if d[p] == 0x23 { escaped = true }
                p += 1
            }
            if !escaped { return PdfName(string(start, p)) }
            var scalars = String.UnicodeScalarView()
            var i = start
            while i < p {
                if d[i] == 0x23 && i + 2 < p && ContentParser.hex(d[i + 1]) >= 0 && ContentParser.hex(d[i + 2]) >= 0 {
                    scalars.append(Unicode.Scalar(UInt8(ContentParser.hex(d[i + 1]) * 16 + ContentParser.hex(d[i + 2]))))
                    i += 2
                } else {
                    scalars.append(Unicode.Scalar(d[i]))
                }
                i += 1
            }
            return PdfName(String(scalars))
        }

        private mutating func readLiteral() -> PdfString {
            p += 1
            var text: [UInt8] = []
            var depth = 1
            while p < d.count {
                var c = d[p]
                p += 1
                if c == 0x5C && p < d.count {
                    let e = d[p]
                    p += 1
                    switch e {
                    case 0x6E: text.append(10)
                    case 0x72: text.append(13)
                    case 0x74: text.append(9)
                    case 0x62: text.append(8)
                    case 0x66: text.append(12)
                    case 13:
                        if at(p) == 10 { p += 1 }
                    case 10: break
                    case 0x30...0x37:
                        var value = Int(e) - 0x30
                        var k = 0
                        while k < 2, let next = at(p), next >= 0x30 && next <= 0x37 {
                            value = value * 8 + (Int(next) - 0x30)
                            p += 1
                            k += 1
                        }
                        // Three octal digits reach 511; (byte)511 is 255 in the unchecked C#.
                        text.append(UInt8(truncatingIfNeeded: value))
                    default: text.append(e)
                    }
                    continue
                }
                if c == 0x28 {
                    depth += 1
                } else if c == 0x29 {
                    depth -= 1
                    if depth == 0 { break }
                }
                if c == 13 {
                    if at(p) == 10 { p += 1 }
                    c = 10
                }
                text.append(c)
            }
            return PdfString(bytes: text, isHex: false)
        }

        private mutating func readHex() -> PdfString {
            p += 1
            var text: [UInt8] = []
            var high = -1
            while p < d.count {
                let c = d[p]
                p += 1
                if c == 0x3E { break }
                let h = ContentParser.hex(c)
                if h < 0 { continue }
                if high < 0 {
                    high = h
                } else {
                    text.append(UInt8(high * 16 + h))
                    high = -1
                }
            }
            if high >= 0 { text.append(UInt8(high * 16)) }
            return PdfString(bytes: text, isHex: true)
        }

        private mutating func readArray(_ depth: Int) -> PdfArray {
            p += 1
            var items: [PdfObject] = []
            if depth >= ContentParser.maxDepth { return PdfArray(items) }
            while true {
                skipSpace()
                if p >= d.count { break }
                if d[p] == 0x5D {
                    p += 1
                    break
                }
                if let value = readValue(depth + 1) {
                    items.append(value)
                    continue
                }
                if ContentParser.isDelimiter(d[p]) {
                    p += 1
                    continue
                }
                // A missing ] ends at the next real operator.
                let from = p
                if ContentParser.known.contains(readWord()) {
                    p = from
                    break
                }
            }
            return PdfArray(items)
        }

        private mutating func readDictionary(_ depth: Int) -> PdfDictionary {
            p += 2
            let dictionary = PdfDictionary()
            if depth >= ContentParser.maxDepth { return dictionary }
            while true {
                skipSpace()
                if p >= d.count { break }
                if d[p] == 0x3E {
                    p += at(p + 1) == 0x3E ? 2 : 1
                    break
                }
                if d[p] == 0x2F {
                    let key = readName().value
                    skipSpace()
                    if at(p) == 0x3E && at(p + 1) == 0x3E {
                        dictionary.add(key, PdfNull.instance)
                    } else if let value = readValue(depth + 1) {
                        dictionary.add(key, value)
                    }
                    continue
                }
                if readValue(depth + 1) != nil { continue }
                if ContentParser.isDelimiter(d[p]) {
                    p += 1
                    continue
                }
                let from = p
                if ContentParser.known.contains(readWord()) {
                    p = from
                    break
                }
            }
            return dictionary
        }

        private mutating func readInlineImage() -> InlineImage {
            let dictionary = PdfDictionary()
            while true {
                skipSpace()
                if p >= d.count { return InlineImage(dictionary, []) }
                if d[p] == 0x2F {
                    let key = readName().value
                    if let value = readValue(0) { dictionary.add(key, value) }
                    continue
                }
                if readValue(0) != nil { continue }
                if ContentParser.isDelimiter(d[p]) {
                    p += 1
                    continue
                }
                let word = readWord()
                if word == "ID" { break }
                if word == "EI" { return InlineImage(dictionary, []) }
            }
            // One white space byte follows ID; CR LF counts as one.
            if at(p) == 13 && at(p + 1) == 10 {
                p += 2
            } else if let c = at(p), ContentParser.isWhite(c) {
                p += 1
            }
            let start = p
            let (end, next) = findImageEnd(dictionary, start)
            p = next
            return InlineImage(dictionary, Array(d[start..<end]))
        }

        private mutating func findImageEnd(_ dictionary: PdfDictionary, _ start: Int) -> (end: Int, next: Int) {
            let length = Self.knownLength(dictionary)
            if length >= 0 && length <= d.count - start {
                let end = start + length
                var q = end
                while q < d.count && ContentParser.isWhite(d[q]) { q += 1 }
                if at(q) == 0x45 && at(q + 1) == 0x49 && (q + 2 >= d.count || !ContentParser.isRegular(d[q + 2])) {
                    return (end, q + 2)
                }
            }
            var i = start
            while i + 1 < d.count {
                defer { i += 1 }
                if d[i] != 0x45 || d[i + 1] != 0x49 { continue }
                if i > start && !ContentParser.isWhite(d[i - 1]) { continue }
                if i + 2 < d.count && ContentParser.isRegular(d[i + 2]) { continue }
                if !looksLikeContent(i + 2) { continue }
                return (i > start ? i - 1 : i, i + 2)
            }
            return (d.count, d.count)
        }

        // Binary data holds "EI" by chance now and then; what follows a real one reads as a content stream.
        private mutating func looksLikeContent(_ from: Int) -> Bool {
            var q = from
            while q < d.count && ContentParser.isWhite(d[q]) { q += 1 }
            let end = Swift.min(d.count, q + 20)
            var i = q
            while i < end {
                let c = d[i]
                if c > 126 || (c < 32 && !ContentParser.isWhite(c)) { return false }
                i += 1
            }
            let first = q < d.count ? d[q] : 0
            if q >= d.count || !((first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)) { return true }
            let save = p
            p = q
            let word = readWord()
            p = save
            return ContentParser.known.contains(word)
        }

        // The size of unfiltered data, when width, height and colour space say it; -1 when they do not, or when the
        // size does not fit a long (the C# wraps there and reads on from a wrong place).
        private static func knownLength(_ dictionary: PdfDictionary) -> Int {
            if dictionary["F"] != nil || dictionary["Filter"] != nil { return -1 }
            guard let w = (dictionary["W"] ?? dictionary["Width"]) as? PdfNumber, w.value > 0,
                  let h = (dictionary["H"] ?? dictionary["Height"]) as? PdfNumber, h.value > 0 else { return -1 }
            var bits = 8
            if let b = (dictionary["BPC"] ?? dictionary["BitsPerComponent"]) as? PdfNumber { bits = Int(saturating32: b.value) }
            var components = 0
            if ((dictionary["IM"] ?? dictionary["ImageMask"]) as? PdfBoolean)?.value == true {
                bits = 1
                components = 1
            } else {
                var space = dictionary["CS"] ?? dictionary["ColorSpace"]
                if let array = space as? PdfArray, !array.items.isEmpty { space = array.items[0] }
                switch (space as? PdfName)?.value {
                case "G", "DeviceGray", "I", "Indexed": components = 1
                case "RGB", "DeviceRGB": components = 3
                case "CMYK", "DeviceCMYK": components = 4
                default: components = 0
                }
            }
            if components == 0 || !(bits == 1 || bits == 2 || bits == 4 || bits == 8 || bits == 16) { return -1 }
            let (perPixel, o1) = Int(saturating: w.value).multipliedReportingOverflow(by: components)
            let (perRow, o2) = perPixel.multipliedReportingOverflow(by: bits)
            let (padded, o3) = perRow.addingReportingOverflow(7)
            let (total, o4) = (padded / 8).multipliedReportingOverflow(by: Int(saturating: h.value))
            return o1 || o2 || o3 || o4 ? -1 : total
        }
    }
}
