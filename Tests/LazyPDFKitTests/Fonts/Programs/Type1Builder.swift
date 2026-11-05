import Foundation
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Fonts/Programs/Type1Builder.cs: writes a small Type 1 font, an encrypted
// private part with Subrs for flex and glyphs that exercise each charstring operator.

enum Type1Wrapper { case binary, hex, pfb }

enum Type1Builder {
    static let glyphNames = [".notdef", "A", "B", "C", "D", "E", "F", "G"]

    private static func num(_ v: Int) -> [UInt8] {
        if v >= -107 && v <= 107 { return [UInt8(v + 139)] }
        if v >= 108 && v <= 1131 { return [UInt8((v - 108) / 256 + 247), UInt8((v - 108) % 256)] }
        if v <= -108 && v >= -1131 { return [UInt8((-v - 108) / 256 + 251), UInt8((-v - 108) % 256)] }
        return [255, UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    private static func op(_ name: String) -> [UInt8] {
        switch name {
        case "hstem": return [1]
        case "vstem": return [3]
        case "vmoveto": return [4]
        case "rlineto": return [5]
        case "hlineto": return [6]
        case "vlineto": return [7]
        case "rrcurveto": return [8]
        case "closepath": return [9]
        case "callsubr": return [10]
        case "return": return [11]
        case "hsbw": return [13]
        case "endchar": return [14]
        case "rmoveto": return [21]
        case "hmoveto": return [22]
        case "vhcurveto": return [30]
        case "hvcurveto": return [31]
        case "dotsection": return [12, 0]
        case "seac": return [12, 6]
        case "sbw": return [12, 7]
        case "div": return [12, 12]
        case "callothersubr": return [12, 16]
        case "pop": return [12, 17]
        case "setcurrentpoint": return [12, 33]
        default: preconditionFailure(name)
        }
    }

    static func code(_ parts: CodePart...) -> [UInt8] {
        code(parts)
    }

    static func code(_ parts: [CodePart]) -> [UInt8] {
        var bytes: [UInt8] = []
        for part in parts {
            switch part {
            case .number(let v): bytes += num(v)
            case .op(let name): bytes += op(name)
            case .raw(let raw): bytes += raw
            }
        }
        return bytes
    }

    static func encrypt(_ plain: [UInt8], _ key: UInt16, _ prefix: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: prefix) + plain
        var r = key
        for i in 0..<data.count {
            let c = data[i] ^ UInt8(truncatingIfNeeded: r >> 8)
            r = (UInt16(c) &+ r) &* 52845 &+ 22719
            data[i] = c
        }
        return data
    }

    private static let subrs: [[UInt8]] = [
        code(3, 0, "callothersubr", "pop", "pop", "setcurrentpoint", "return"),
        code(0, 1, "callothersubr", "return"),
        code(0, 2, "callothersubr", "return"),
        code("return"),
    ]

    private static func glyphs() -> [[UInt8]] {
        var flex: [CodePart] = [0, 500, "hsbw", 10, 10, "rmoveto", 1, "callsubr"]
        for (dx, dy) in [(50, 0), (-30, 0), (10, 5), (10, 0), (10, 0), (10, -5), (10, 0)] {
            flex += [.number(dx), .number(dy), "rmoveto", 2, "callsubr"]
        }
        flex += [50, 80, 10, 0, "callsubr", 0, 100, "rlineto", "closepath", "endchar"]

        return [
            code(0, 250, "hsbw", "endchar"),
            code(50, 600, "hsbw", 0, 0, "rmoveto", 100, "hlineto", 100, "vlineto", -100, "hlineto", "closepath", "endchar"),
            code(flex),
            code(0, 700, "hsbw", 20, 30, 40, 65, 66, "seac"),
            code(0, 400, "hsbw", 0, 0, "rmoveto", 100, 2, "div", "hlineto", "closepath", "endchar"),
            code(0, 300, "hsbw", 0, 0, "rmoveto", 3, 1, 3, "callothersubr", "pop", "callsubr", 10, "hlineto", "closepath", "endchar"),
            code(10, 20, 300, 0, "sbw", 0, 0, "rmoveto", 5, "vlineto", "closepath", "endchar"),
            code(0, 400, "hsbw", 0, 0, "rmoveto", 10, 0, 0, 10, 10, 0, "rrcurveto", 5, 10, 10, 5, "vhcurveto", 3, 4, 5, 6, "hvcurveto", "closepath", "endchar"),
        ]
    }

    /// `lenIV`: random bytes in front of each charstring; -1 leaves them unencrypted.
    /// `barNames`: use the -| |- | names of the usual font programs for RD, ND and NP.
    static func build(_ wrapper: Type1Wrapper, _ lenIV: Int = 4, _ barNames: Bool = false) -> [UInt8] {
        let rd = barNames ? "-|" : "RD"
        let nd = barNames ? "|-" : "ND"
        let np = barNames ? "|" : "NP"

        let clear = Latin1.bytes(
            "%!PS-AdobeFont-1.0: TestFont 001.000\n11 dict begin\n" +
            "/FontInfo 2 dict dup begin /Notice (Test /Encoding in a string) readonly def end readonly def\n" +
            "/FontName /TestFont def\n/PaintType 0 def\n/FontType 1 def\n/FontMatrix [0.001 0 0 0.001 0 0] readonly def\n" +
            "/Encoding 256 array\n0 1 255 {1 index exch /.notdef put} for\ndup 65 /A put\ndup 66 /B put\ndup 8#103 /C put\nreadonly def\n" +
            "/FontBBox {-10 -20 900 800} readonly def\ncurrentdict end\ncurrentfile eexec\n")

        var priv: [UInt8] = []
        func text(_ s: String) {
            priv += Latin1.bytes(s)
        }
        func lock(_ cs: [UInt8]) -> [UInt8] {
            lenIV < 0 ? cs : encrypt(cs, 4330, lenIV)
        }

        text("dup /Private 8 dict dup begin\n/\(rd) {string currentfile exch readstring pop} executeonly def\n")
        text("/\(nd) {noaccess def} executeonly def\n/\(np) {noaccess put} executeonly def\n/BlueValues [] def\n/password 5839 def\n")
        if lenIV != 4 { text("/lenIV \(lenIV) def\n") }
        text("/Subrs \(subrs.count) array\n")
        for i in 0..<subrs.count {
            let cs = lock(subrs[i])
            text("dup \(i) \(cs.count) \(rd) ")
            priv += cs
            text(" \(np)\n")
        }
        text("\(nd)\n2 index /CharStrings \(glyphNames.count) dict dup begin\n")
        let all = glyphs()
        for i in 0..<all.count {
            let cs = lock(all[i])
            text("/\(glyphNames[i]) \(cs.count) \(rd) ")
            priv += cs
            text(" \(nd)\n")
        }
        text("end\nend\nreadonly put\nnoaccess put\ndup /FontName get exch definefont pop\nmark currentfile closefile\n")

        let encrypted = encrypt(priv, 55665, 4)
        let zeros = String(repeating: "0", count: 64)
        let trailer = Latin1.bytes(String(repeating: zeros + "\n", count: 8) + "cleartomark\n")

        switch wrapper {
        case .hex:
            let digits = Array("0123456789ABCDEF".utf8)
            var hex: [UInt8] = []
            for b in encrypted {
                hex.append(digits[Int(b >> 4)])
                hex.append(digits[Int(b & 15)])
            }
            var lines: [[UInt8]] = []
            var at = 0
            while at < hex.count {
                lines.append(Array(hex[at..<min(at + 64, hex.count)]))
                at += 64
            }
            var body: [UInt8] = []
            for (i, line) in lines.enumerated() {
                if i > 0 { body.append(10) }
                body += line
            }
            body.append(10)
            return clear + body + trailer
        case .pfb:
            return segment(1, clear) + segment(2, encrypted) + segment(1, trailer) + [0x80, 3]
        case .binary:
            return clear + encrypted + trailer
        }
    }

    private static func segment(_ type: UInt8, _ data: [UInt8]) -> [UInt8] {
        let n = data.count
        return [0x80, type, UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 24)] + data
    }
}
