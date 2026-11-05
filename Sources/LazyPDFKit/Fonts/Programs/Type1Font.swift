import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Programs/Type1Font.cs: a Type 1 font program (Adobe Type 1 Font Format) in
// PFA, PFB or the bare form of a PDF's FontFile: the clear-text header, then the eexec-encrypted private part
// with Subrs and CharStrings.

public final class Type1Font {
    private static let maxGlyphs = 65536
    private static let maxSubrs = 65536

    private var charStrings: [String: [UInt8]] = [:]
    private(set) var subrs: [[UInt8]?] = []

    public private(set) var fontName = ""

    /// FontMatrix, 0.001 0 0 0.001 0 0 when the header has none.
    public private(set) var fontMatrix: [Double] = [0.001, 0, 0, 0.001, 0, 0]

    public private(set) var fontBounds: GlyphBounds?

    /// The built-in encoding: the glyph name of each code, nil where none is assigned.
    public private(set) var builtInEncoding = [String?](repeating: nil, count: 256)

    /// Glyph names in file order.
    public private(set) var glyphNames: [String] = []

    private init() {}

    public func hasGlyph(_ name: String) -> Bool {
        charStrings[name] != nil
    }

    func charString(_ name: String) -> [UInt8]? {
        charStrings[name]
    }

    /// Advance width of the named glyph in font units, 0 when the glyph does not exist.
    public func getWidth(_ name: String) -> Double {
        run(name, true)?.width ?? 0
    }

    /// Outline of the named glyph in font units (cubic curves), nil when it does not exist.
    /// Flex sequences become two curves and accented characters (seac) are composed.
    public func getOutline(_ name: String) -> GlyphOutline? {
        run(name, true)?.outline
    }

    func run(_ name: String, _ allowSeac: Bool) -> Type1Glyph? {
        charStrings[name] != nil ? Type1Interpreter(self, allowSeac).run(name) : nil
    }

    /// Parses a PFA, PFB or FontFile stream; nil when no glyph can be found in it.
    public static func tryParse(_ data: [UInt8]) -> Type1Font? {
        let (clear, encrypted) = splitSegments(data)
        let font = Type1Font()
        font.readHeader(clear)

        let priv = encrypted.isEmpty ? clear : decrypt(encrypted, 55665, 4)
        font.readPrivate(priv)
        return font.charStrings.isEmpty ? nil : font
    }

    private static func splitSegments(_ data: [UInt8]) -> (clear: [UInt8], encrypted: [UInt8]) {
        if data.count > 6 && data[0] == 0x80 {
            var c: [UInt8] = []
            var e: [UInt8] = []
            var p = 0
            while p + 6 <= data.count && data[p] == 0x80 && (data[p + 1] == 1 || data[p + 1] == 2) {
                // The length is little-endian.
                var len: UInt32 = 0
                for k in 0..<4 { len |= UInt32(data[p + 2 + k]) << UInt32(8 * k) }
                let n = Int(min(len, UInt32(clamping: data.count - p - 6)))
                if data[p + 1] == 1 {
                    if e.isEmpty { c.append(contentsOf: data[p + 6..<p + 6 + n]) }
                } else {
                    e.append(contentsOf: data[p + 6..<p + 6 + n])
                }
                p += 6 + n
            }
            return (c, e)
        }

        let key = Array("eexec".utf8)
        var at = -1
        var i = 0
        while i + key.count <= data.count {
            if data[i] == key[0] && Array(data[i..<i + key.count]) == key {
                at = i
                break
            }
            i += 1
        }
        if at < 0 { return (data, []) }
        var start = at + 5
        let clear = Array(data[..<start])
        while start < data.count && (data[start] == 0x20 || data[start] == 0x09 || data[start] == 0x0D || data[start] == 0x0A) { start += 1 }
        let rest = Array(data[start...])
        return (clear, isHex(rest) ? decodeHex(rest) : rest)
    }

    private static func isHexDigit(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    private static func isHex(_ d: [UInt8]) -> Bool {
        if d.count < 4 { return false }
        for i in 0..<4 where !isHexDigit(d[i]) { return false }
        return true
    }

    private static func decodeHex(_ d: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(d.count / 2)
        var high = -1
        for b in d {
            if b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A { continue }
            if !isHexDigit(b) { break }
            let v = b <= 0x39 ? Int(b) - 0x30 : (b <= 0x46 ? Int(b) - 0x41 + 10 : Int(b) - 0x61 + 10)
            if high < 0 {
                high = v
            } else {
                result.append(UInt8(high << 4 | v))
                high = -1
            }
        }
        return result
    }

    /// The eexec and charstring cipher (Type 1 Font Format, chapter 7); the first `skip` bytes are random padding.
    static func decrypt(_ cipher: [UInt8], _ key: UInt16, _ skip: Int) -> [UInt8] {
        if cipher.count <= skip { return [] }
        var plain = [UInt8](repeating: 0, count: cipher.count - skip)
        var r = key
        for i in 0..<cipher.count {
            let c = cipher[i]
            if i >= skip { plain[i - skip] = c ^ UInt8(truncatingIfNeeded: r >> 8) }
            // The C# computes this in int and keeps the low 16 bits; the wrapping ops give the same bits.
            r = (UInt16(c) &+ r) &* 52845 &+ 22719
        }
        return plain
    }

    private static func startsWithSlash(_ text: String) -> Bool {
        text.unicodeScalars.first == "/"
    }

    private static func withoutSlash(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.dropFirst()))
    }

    private func readHeader(_ clear: [UInt8]) {
        var s = Scanner(clear)
        if s.seekAfter("/FontName"), let name = s.next(), Type1Font.startsWithSlash(name) { fontName = Type1Font.withoutSlash(name) }

        s = Scanner(clear)
        if s.seekAfter("/FontMatrix"), let m = s.numbers(), m.count == 6 { fontMatrix = m }

        s = Scanner(clear)
        if s.seekAfter("/FontBBox"), let b = s.numbers(), b.count == 4 { fontBounds = GlyphBounds(b[0], b[1], b[2], b[3]) }

        s = Scanner(clear)
        while s.seekAfter("/Encoding") {
            if readEncoding(s) { break }
        }
    }

    /// False when the key was not the encoding entry (a string in the notice can hold the same word).
    private func readEncoding(_ s: Scanner) -> Bool {
        let first = s.next()
        if first == "StandardEncoding" {
            builtInEncoding = StandardNames.standardEncoding
            return true
        }
        if FontBytes.parseInt32(first) == nil { return false }
        for _ in 0..<8192 {
            guard let t = s.next(), t != "def" else { break }
            if t != "dup" { continue }
            let code = s.next()
            let name = s.next()
            if let code, let name, Type1Font.startsWithSlash(name), let c = Type1Font.parseCode(code), c >= 0, c < 256 {
                builtInEncoding[c] = Type1Font.withoutSlash(name)
            }
        }
        return true
    }

    private static func parseCode(_ token: String) -> Int? {
        let scalars = Array(token.unicodeScalars)
        if let hash = scalars.firstIndex(of: "#"), hash > 0 {
            guard let radix = FontBytes.parseInt32(String(String.UnicodeScalarView(scalars[..<hash]))), radix >= 2, radix <= 36 else { return nil }
            return radixValue(Array(scalars[(hash + 1)...]), radix)
        }
        // NumberStyles.None: digits only.
        if scalars.isEmpty || !scalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) { return nil }
        return Int32(token).map { Int($0) }
    }

    private static func radixValue(_ digits: [Unicode.Scalar], _ radix: Int) -> Int? {
        var v = 0
        for ch in digits {
            let d: Int
            if ch.value >= 0x30 && ch.value <= 0x39 {
                d = Int(ch.value) - 0x30
            } else if ch.value >= 0x61 && ch.value <= 0x7A {
                d = Int(ch.value) - 0x61 + 10
            } else if ch.value >= 0x41 && ch.value <= 0x5A {
                d = Int(ch.value) - 0x41 + 10
            } else {
                d = 99
            }
            if d >= radix { return nil }
            v = v * radix + d
            if v > 100000 { return nil }
        }
        return v
    }

    private func readPrivate(_ d: [UInt8]) {
        var lenIV = 4
        var s = Scanner(d)
        if s.seekAfter("/lenIV"), let iv = FontBytes.parseInt32(s.next()), iv >= -1, iv <= 64 { lenIV = iv }

        s = Scanner(d)
        if s.seekAfter("/Subrs"), let count = FontBytes.parseInt32(s.next()), count > 0, count <= Type1Font.maxSubrs {
            subrs = [[UInt8]?](repeating: nil, count: count)
            readSubrs(s, lenIV)
        }

        s = Scanner(d)
        if s.seekAfter("/CharStrings") { readCharStrings(s, lenIV) }
    }

    private func readSubrs(_ s: Scanner, _ lenIV: Int) {
        while let t = s.next() {
            if Type1Font.startsWithSlash(t) { break }
            if t != "dup" { continue }
            guard let index = FontBytes.parseInt32(s.next()) else { break }
            let len = s.nextInt()
            guard s.next() != nil, let bytes = s.binary(len) else { break }
            if index >= 0 && index < subrs.count { subrs[index] = Type1Font.unlock(bytes, lenIV) }
        }
    }

    private func readCharStrings(_ s: Scanner, _ lenIV: Int) {
        while let t = s.next(), t != "end", glyphNames.count < Type1Font.maxGlyphs {
            if !Type1Font.startsWithSlash(t) { continue }
            let len = s.nextInt()
            guard s.next() != nil, let bytes = s.binary(len) else { break }
            let name = Type1Font.withoutSlash(t)
            if charStrings[name] == nil {
                charStrings[name] = Type1Font.unlock(bytes, lenIV)
                glyphNames.append(name)
            }
        }
    }

    private static func unlock(_ cipher: [UInt8], _ lenIV: Int) -> [UInt8] {
        lenIV < 0 ? cipher : decrypt(cipher, 4330, lenIV)
    }

    /// A PostScript token reader over the font text; binary charstrings are skipped by length.
    private final class Scanner {
        private let d: [UInt8]
        private var p = 0

        init(_ d: [UInt8]) {
            self.d = d
        }

        private static func isSpace(_ b: UInt8) -> Bool {
            b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32
        }

        private static func isDelimiter(_ b: UInt8) -> Bool {
            switch b {
            case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
            default: return false
            }
        }

        func seekAfter(_ key: String) -> Bool {
            let k = Array(key.utf8)
            var i = p
            while i + k.count <= d.count {
                if d[i] == k[0] && Array(d[i..<i + k.count]) == k {
                    p = i + k.count
                    return true
                }
                i += 1
            }
            return false
        }

        func next() -> String? {
            while p < d.count {
                if Scanner.isSpace(d[p]) {
                    p += 1
                } else if d[p] == 0x25 {
                    while p < d.count && d[p] != 10 && d[p] != 13 { p += 1 }
                } else {
                    break
                }
            }
            if p >= d.count { return nil }

            let start = p
            p += 1
            if d[start] == 0x2F || !Scanner.isDelimiter(d[start]) {
                while p < d.count && !Scanner.isSpace(d[p]) && !Scanner.isDelimiter(d[p]) { p += 1 }
            }
            return Latin1.string(Array(d[start..<p]))
        }

        func nextInt() -> Int {
            // NumberStyles.AllowLeadingSign: no white space around the digits.
            guard let text = next(), let v = Int32(text) else { return -1 }
            return Int(v)
        }

        /// The bytes after the RD token: one separator, then `length` bytes. Nil when they do not fit.
        func binary(_ length: Int) -> [UInt8]? {
            if length < 0 || length > d.count - p - 1 { return nil }
            let bytes = Array(d[p + 1..<p + 1 + length])
            p += 1 + length
            return bytes
        }

        /// Numbers of a [ ... ] or { ... } list, nil when the list is missing or holds anything else.
        func numbers() -> [Double]? {
            guard let bracket = next(), bracket == "[" || bracket == "{" else { return nil }
            var list: [Double] = []
            while let t = next(), t != "]", t != "}" {
                guard let v = FontBytes.parseDouble(t) else { return nil }
                if list.count >= 16 { return nil }
                list.append(v)
            }
            return list
        }
    }
}

struct Type1Glyph {
    let outline: GlyphOutline
    let width: Double
}
