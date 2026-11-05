import Foundation

// Twin of windows/LazyPDF.Core/Filters/AsciiFilters.cs: ASCIIHexDecode, ASCII85Decode and RunLengthDecode
// (ISO 32000-1 7.4.2, 7.4.3, 7.4.5).

enum AsciiFilters {
    static func decodeHex(_ data: [UInt8], _ maxSize: Int) throws -> [UInt8] {
        let output = FilterBuffer(maxSize, capacity: data.count / 2)
        var high = -1
        for b in data {
            if b == UInt8(ascii: ">") { break }
            if PdfLexer.isWhiteSpace(Int(b)) { continue }
            let digit = hexValue(b)
            if digit < 0 { throw PdfReadException.damaged("ASCIIHexDecode data holds a character that is not a hex digit.") }
            if high < 0 {
                high = digit
            } else {
                try output.add(UInt8(high << 4 | digit))
                high = -1
            }
        }
        // An odd last digit stands for a digit and a zero.
        if high >= 0 { try output.add(UInt8(high << 4)) }
        return output.toArray()
    }

    static func decode85(_ data: [UInt8], _ maxSize: Int) throws -> [UInt8] {
        let output = FilterBuffer(maxSize, capacity: data.count)
        let start = data.count >= 2 && data[0] == UInt8(ascii: "<") && data[1] == UInt8(ascii: "~") ? 2 : 0
        var group = [UInt8](repeating: 0, count: 5)
        var count = 0
        var i = start
        while i < data.count {
            let b = data[i]
            i += 1
            if b == UInt8(ascii: "~") { break }
            if PdfLexer.isWhiteSpace(Int(b)) { continue }
            if b == UInt8(ascii: "z") && count == 0 {
                try output.append(4, filling: 0)
                continue
            }
            if b < UInt8(ascii: "!") || b > UInt8(ascii: "u") {
                throw PdfReadException.damaged("ASCII85Decode data holds a character outside ! to u.")
            }
            group[count] = b - UInt8(ascii: "!")
            count += 1
            if count == 5 {
                try emit(group, 5, output)
                count = 0
            }
        }
        // A short last group of n characters gives n - 1 bytes; a lone character gives none.
        if count > 1 {
            for j in count..<5 { group[j] = 84 }
            try emit(group, count, output)
        }
        return output.toArray()
    }

    private static func emit(_ group: [UInt8], _ characters: Int, _ output: FilterBuffer) throws {
        var value: UInt32 = 0
        for digit in group { value = value &* 85 &+ UInt32(digit) }
        let four = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                    UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        try output.add(four[..<(characters - 1)])
    }

    static func decodeRunLength(_ data: [UInt8], _ maxSize: Int) throws -> [UInt8] {
        let output = FilterBuffer(maxSize, capacity: data.count * 2)
        var i = 0
        while i < data.count {
            let length = Int(data[i])
            i += 1
            if length == 128 { break }
            if length < 128 {
                let count = min(length + 1, data.count - i)
                try output.add(data[i..<i + count])
                i += count
            } else if i < data.count {
                try output.append(257 - length, filling: data[i])
                i += 1
            }
        }
        return output.toArray()
    }

    private static func hexValue(_ b: UInt8) -> Int {
        switch b {
        case 0x30...0x39: return Int(b) - 0x30
        case 0x61...0x66: return Int(b) - 0x61 + 10
        case 0x41...0x46: return Int(b) - 0x41 + 10
        default: return -1
        }
    }
}
