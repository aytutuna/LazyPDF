import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/FontBytes.cs: big-endian reads that return 0 past the end, so a
// truncated table gives zeros and never a trap. FontSpan stands for ReadOnlySpan<byte>: a window on an array
// that is shared, not copied, and whose offsets start at 0 wherever the window lies. The reads of the C# static
// class are its methods.

struct FontSpan {
    let bytes: [UInt8]
    let start: Int
    let length: Int

    static let empty = FontSpan([])

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        start = 0
        length = bytes.count
    }

    /// `length` bytes from `start`; callers pass a window that lies inside `bytes`.
    init(_ bytes: [UInt8], _ start: Int, _ length: Int) {
        self.bytes = bytes
        self.start = start
        self.length = length
    }

    subscript(i: Int) -> UInt8 {
        bytes[start + i]
    }

    /// The window `count` bytes long from `offset`, cut to what the span holds (C# would throw).
    func slice(_ offset: Int, _ count: Int) -> FontSpan {
        let o = min(max(offset, 0), length)
        let n = min(max(count, 0), length - o)
        return FontSpan(bytes, start + o, n)
    }

    func slice(from offset: Int) -> FontSpan {
        slice(offset, length - min(max(offset, 0), length))
    }

    func toArray() -> [UInt8] {
        Array(bytes[start..<start + length])
    }

    func u8(_ o: Int) -> Int {
        o >= 0 && o < length ? Int(bytes[start + o]) : 0
    }

    func u16(_ o: Int) -> Int {
        o >= 0 && o <= length - 2 ? (Int(bytes[start + o]) << 8) | Int(bytes[start + o + 1]) : 0
    }

    func i16(_ o: Int) -> Int {
        Int(Int16(truncatingIfNeeded: u16(o)))
    }

    func u24(_ o: Int) -> Int {
        o >= 0 && o <= length - 3 ? (Int(bytes[start + o]) << 16) | (Int(bytes[start + o + 1]) << 8) | Int(bytes[start + o + 2]) : 0
    }

    func u32(_ o: Int) -> UInt32 {
        guard o >= 0 && o <= length - 4 else { return 0 }
        let a = UInt32(bytes[start + o]) << 24
        let b = UInt32(bytes[start + o + 1]) << 16
        let c = UInt32(bytes[start + o + 2]) << 8
        return a | b | c | UInt32(bytes[start + o + 3])
    }

    /// A 32-bit offset or length, 0 when it is larger than an int could address.
    func offset32(_ o: Int) -> Int {
        let v = u32(o)
        return v > UInt32(Int32.max) ? 0 : Int(v)
    }

    func tag(_ o: Int) -> String {
        if o < 0 || o > length - 4 { return "" }
        return Latin1.string(Array(bytes[start + o..<start + o + 4]))
    }

    /// The sum of 32-bit words of the span, the last word padded with zeros (OpenType "Table checksums").
    func checksum() -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i + 4 <= length {
            sum = sum &+ u32(i)
            i += 4
        }
        if i < length {
            var last: UInt32 = 0
            for k in 0..<4 {
                last = (last << 8) | (i + k < length ? UInt32(bytes[start + i + k]) : 0)
            }
            sum = sum &+ last
        }
        return sum
    }
}

enum FontBytes {
    static func putU16(_ d: inout [UInt8], _ o: Int, _ v: Int) {
        d[o] = UInt8(truncatingIfNeeded: v >> 8)
        d[o + 1] = UInt8(truncatingIfNeeded: v)
    }

    static func putU32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) {
        d[o] = UInt8(truncatingIfNeeded: v >> 24)
        d[o + 1] = UInt8(truncatingIfNeeded: v >> 16)
        d[o + 2] = UInt8(truncatingIfNeeded: v >> 8)
        d[o + 3] = UInt8(truncatingIfNeeded: v)
    }

    /// C# `(int)x` on a double: .NET saturates, with NaN as 0. The result is in the range of an Int32.
    static func toInt32(_ v: Double) -> Int {
        if v.isNaN { return 0 }
        if v >= 2147483647 { return Int(Int32.max) }
        if v <= -2147483648 { return Int(Int32.min) }
        return Int(v)
    }

    /// `double.TryParse(text, NumberStyles.Float, InvariantCulture)`. Swift also reads "inf", "nan" and hex
    /// floats, which .NET does not, and .NET reads "Infinity" and "NaN".
    static func parseDouble(_ text: String) -> Double? {
        let body = trimmed(text)
        if body.isEmpty { return nil }
        let plain = body.unicodeScalars.allSatisfy { "+-.0123456789eE".unicodeScalars.contains($0) }
        if plain { return Double(body) }
        switch body.lowercased() {
        case "infinity", "+infinity": return Double.infinity
        case "-infinity": return -Double.infinity
        case "nan", "+nan", "-nan": return Double.nan
        default: return nil
        }
    }

    /// `int.TryParse(text)`: a sign and digits, white space around them allowed, the range of an Int32.
    static func parseInt32(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int32(trimmed(text)).map { Int($0) }
    }

    private static func trimmed(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, isWhite(last) { scalars.removeLast() }
        var first = 0
        while first < scalars.count && isWhite(scalars[first]) { first += 1 }
        return String(String.UnicodeScalarView(scalars[first...]))
    }

    private static func isWhite(_ c: Unicode.Scalar) -> Bool {
        c.value == 0x20 || (c.value >= 0x09 && c.value <= 0x0D)
    }
}
