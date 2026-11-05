import Foundation

// Twin of windows/LazyPDF.Core/Filters/PdfFilterEncoders.cs: the writing side of the filters a writer chooses from.

public enum PdfFilterEncoders {
    public static func flate(_ data: [UInt8], _ level: CompressionLevel = .optimal) -> [UInt8] {
        Deflate.zlib(data, level)
    }

    /// Hex digits in upper case and the closing ">".
    public static func asciiHex(_ data: [UInt8]) -> [UInt8] {
        let digits = Array("0123456789ABCDEF".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(data.count * 2 + 1)
        for b in data {
            output.append(digits[Int(b >> 4)])
            output.append(digits[Int(b & 15)])
        }
        output.append(UInt8(ascii: ">"))
        return output
    }

    /// Base-85 text with "z" for a group of four zero bytes and the closing "~>".
    public static func ascii85(_ data: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(data.count / 4 * 5 + 8)
        var chars = [UInt8](repeating: 0, count: 5)
        var i = 0
        while i < data.count {
            let n = min(4, data.count - i)
            var value: UInt32 = 0
            for j in 0..<4 { value = value << 8 | (j < n ? UInt32(data[i + j]) : 0) }
            i += 4
            if value == 0 && n == 4 {
                output.append(UInt8(ascii: "z"))
                continue
            }
            for j in stride(from: 4, through: 0, by: -1) {
                chars[j] = UInt8(value % 85) + UInt8(ascii: "!")
                value /= 85
            }
            for j in 0..<n + 1 { output.append(chars[j]) }
        }
        output.append(contentsOf: Array("~>".utf8))
        return output
    }

    public static func runLength(_ data: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(data.count + data.count / 64 + 2)
        var i = 0
        while i < data.count {
            var run = 1
            while i + run < data.count && run < 128 && data[i + run] == data[i] { run += 1 }
            if run >= 2 {
                output.append(UInt8(257 - run))
                output.append(data[i])
                i += run
                continue
            }
            var end = i + 1
            while end < data.count && end - i < 128 && !(end + 1 < data.count && data[end] == data[end + 1]) { end += 1 }
            output.append(UInt8(end - i - 1))
            output.append(contentsOf: data[i..<end])
            i = end
        }
        output.append(128)
        return output
    }

    public static func lzw(_ data: [UInt8], _ earlyChange: Bool = true) -> [UInt8] {
        LzwCodec.encode(data, earlyChange)
    }
}
