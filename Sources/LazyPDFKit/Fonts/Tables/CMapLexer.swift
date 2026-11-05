import Foundation

// Twin of windows/LazyPDF.Core/Fonts/Tables/CMapLexer.cs: tokens of a CMap file. A hex string is decoded into a
// small buffer and cut off at its size: a destination string longer than that is not text a font maps one
// code to.
struct CMapLexer {
    enum Kind { case end, name, hex, number, word, arrayOpen, arrayClose, other }

    private static let hexCapacity = 256

    private let data: [UInt8]
    private var hex = [UInt8](repeating: 0, count: CMapLexer.hexCapacity)
    private var at = 0
    private var textStart = 0, textLength = 0, hexLength = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    private(set) var number = 0

    /// The name (without the slash) or the word last read.
    var text: ArraySlice<UInt8> {
        data[textStart..<textStart + textLength]
    }

    mutating func next() -> Kind {
        skipSpace()
        if at >= data.count {
            return .end
        }
        let c = data[at]
        let second: UInt8? = at + 1 < data.count ? data[at + 1] : nil
        switch c {
        case UInt8(ascii: "/"):
            at += 1
            regular()
            return .name
        case UInt8(ascii: "<") where second == UInt8(ascii: "<"), UInt8(ascii: ">") where second == UInt8(ascii: ">"):
            at += 2
            return .other
        case UInt8(ascii: "<"):
            at += 1
            readHex()
            return .hex
        case UInt8(ascii: "["):
            at += 1
            return .arrayOpen
        case UInt8(ascii: "]"):
            at += 1
            return .arrayClose
        case UInt8(ascii: "("):
            skipString()
            return .other
        case UInt8(ascii: ">"), UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"):
            at += 1
            return .other
        default:
            break
        }
        regular()
        return tryNumber() ? .number : .word
    }

    /// The bytes of a code in a hex string as a number; nil when it is empty or longer than four bytes.
    func code() -> (code: UInt32, length: Int)? {
        if hexLength < 1 || hexLength > 4 {
            return nil
        }
        var code: UInt32 = 0
        for i in 0..<hexLength {
            code = code << 8 | UInt32(hex[i])
        }
        return (code, hexLength)
    }

    /// The hex string as UTF-16BE text (ISO 32000-1 9.10.3); a single byte stands for the character of that value.
    func utf16() -> [UInt16] {
        let length = min(hexLength, Self.hexCapacity)
        if length == 1 {
            return [UInt16(hex[0])]
        }
        return (0..<length / 2).map { UInt16(hex[2 * $0]) << 8 | UInt16(hex[2 * $0 + 1]) }
    }

    private mutating func skipSpace() {
        while at < data.count {
            let c = data[at]
            if c == UInt8(ascii: "%") {
                while at < data.count && data[at] != 10 && data[at] != 13 {
                    at += 1
                }
            } else if Self.isSpace(c) {
                at += 1
            } else {
                return
            }
        }
    }

    private mutating func regular() {
        textStart = at
        while at < data.count && !Self.isSpace(data[at]) && !Self.isDelimiter(data[at]) {
            at += 1
        }
        textLength = at - textStart
    }

    private mutating func tryNumber() -> Bool {
        let t = text
        guard let first = t.first else {
            return false
        }
        let start = first == UInt8(ascii: "-") || first == UInt8(ascii: "+") ? 1 : 0
        if start == t.count || t.count - start > 18 {
            return false
        }
        var value = 0
        for byte in t.dropFirst(start) {
            if byte < UInt8(ascii: "0") || byte > UInt8(ascii: "9") {
                return false
            }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        number = first == UInt8(ascii: "-") ? -value : value
        return true
    }

    private mutating func readHex() {
        hexLength = 0
        var half = -1
        while at < data.count {
            let c = data[at]
            at += 1
            if c == UInt8(ascii: ">") {
                break
            }
            let digit = Self.hexValue(c)
            if digit < 0 {
                continue
            }
            if half < 0 {
                half = digit
            } else {
                store(half << 4 | digit)
                half = -1
            }
        }
        if half >= 0 {
            store(half << 4)
        }
    }

    // Past the buffer the length keeps counting, so a caller can tell the string was cut off.
    private mutating func store(_ value: Int) {
        if hexLength < Self.hexCapacity {
            hex[hexLength] = UInt8(value)
        }
        if hexLength < Int(Int32.max) {
            hexLength += 1
        }
    }

    private mutating func skipString() {
        var depth = 0
        while at < data.count {
            let c = data[at]
            at += 1
            if c == UInt8(ascii: "\\") {
                at += 1
            } else if c == UInt8(ascii: "(") {
                depth += 1
            } else if c == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 {
                    return
                }
            }
        }
    }

    private static func hexValue(_ c: UInt8) -> Int {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(c - UInt8(ascii: "0"))
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(c - UInt8(ascii: "A")) + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(c - UInt8(ascii: "a")) + 10
        default: return -1
        }
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32
    }

    private static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"),
             UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "/"), UInt8(ascii: "%"):
            return true
        default:
            return false
        }
    }
}
