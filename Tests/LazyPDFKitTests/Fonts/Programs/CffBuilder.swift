import Foundation
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Fonts/Programs/CffBuilder.cs: assembles small CFF programs by hand so the
// charstring interpreter is tested without a font file.

/// One part of a charstring: an operand, an operator by name, or raw bytes (the C# takes object[]).
enum CodePart: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case number(Int)
    case op(String)
    case raw([UInt8])

    init(integerLiteral value: Int) {
        self = .number(value)
    }

    init(stringLiteral value: String) {
        self = .op(value)
    }
}

enum CffBuilder {
    static func num(_ v: Int) -> [UInt8] {
        if v >= -107 && v <= 107 { return [UInt8(v + 139)] }
        if v >= 108 && v <= 1131 { return [UInt8((v - 108) / 256 + 247), UInt8((v - 108) % 256)] }
        return [28, UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    /// Numbers and operators: ints become operands, strings are operator names.
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

    private static func op(_ name: String) -> [UInt8] {
        switch name {
        case "hstem": return [1]
        case "vstem": return [3]
        case "vmoveto": return [4]
        case "rlineto": return [5]
        case "hlineto": return [6]
        case "vlineto": return [7]
        case "rrcurveto": return [8]
        case "callsubr": return [10]
        case "return": return [11]
        case "endchar": return [14]
        case "hstemhm": return [18]
        case "hintmask": return [19]
        case "rmoveto": return [21]
        case "hmoveto": return [22]
        case "vstemhm": return [23]
        case "rcurveline": return [24]
        case "rlinecurve": return [25]
        case "vvcurveto": return [26]
        case "hhcurveto": return [27]
        case "callgsubr": return [29]
        case "vhcurveto": return [30]
        case "hvcurveto": return [31]
        case "flex": return [12, 35]
        case "hflex": return [12, 34]
        case "hflex1": return [12, 36]
        case "flex1": return [12, 37]
        case "add": return [12, 10]
        case "sub": return [12, 11]
        case "mul": return [12, 24]
        case "div": return [12, 12]
        case "dup": return [12, 27]
        case "exch": return [12, 28]
        case "drop": return [12, 18]
        default: preconditionFailure(name)
        }
    }

    static func index(_ items: [UInt8]...) -> [UInt8] {
        if items.isEmpty { return [0, 0] }
        var bytes = u16(items.count) + [2]
        var offset = 1
        bytes += u16(offset)
        for item in items {
            offset += item.count
            bytes += u16(offset)
        }
        for item in items { bytes += item }
        return bytes
    }

    private static func int(_ v: Int) -> [UInt8] {
        [29, UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    /// A DICT with every operand as a five-byte integer, so its size does not depend on the values.
    static func dict(_ entries: (op: Int, operands: [Int])...) -> [UInt8] {
        var bytes: [UInt8] = []
        for (op, operands) in entries {
            for v in operands { bytes += int(v) }
            if op >= 1200 {
                bytes += [12, UInt8(op - 1200)]
            } else {
                bytes.append(UInt8(op))
            }
        }
        return bytes
    }

    private static func concat(_ parts: [UInt8]...) -> [UInt8] {
        parts.flatMap { $0 }
    }

    private static func text(_ s: String) -> [UInt8] {
        Array(s.utf8)
    }

    static let square = code(100, 50, 0, "rmoveto", 100, 0, 0, 100, -100, 0, "rlineto", "endchar")

    static let curve = code(10, 20, "rmoveto", -107, "callsubr", "endchar")

    static let curveSubr = code(30, 0, 0, 30, 30, 0, "rrcurveto", "return")

    static let masked = code(0, 10, 20, 10, "hstemhm", "hintmask", .raw([0xC0]), 100, 100, "rmoveto", 10, 20, "hlineto", "endchar")

    private static let privateSize = 18

    private static func u16(_ v: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    /// Glyphs: .notdef, A (width 100 above the nominal), B (a curve through a local subroutine), "custom" (hint mask).
    /// Name-keyed: nominal width 500, default 300.
    static func nameKeyed(_ subr: [UInt8]? = nil) -> [UInt8] {
        let charset = concat([0], u16(34), u16(35), u16(391))
        let glyphs = index([14], square, curve, masked)
        let priv = concat(dict((20, [300]), (21, [500]), (19, [privateSize])), index(subr ?? curveSubr))

        func head(_ charsetAt: Int, _ glyphsAt: Int, _ privAt: Int) -> [UInt8] {
            concat([1, 0, 4, 2], index(text("Test")),
                   index(dict((15, [charsetAt]), (17, [glyphsAt]), (18, [privateSize, privAt]), (5, [0, 0, 200, 200]))),
                   index(text("custom")), index())
        }

        let h = head(0, 0, 0).count
        return concat(head(h, h + charset.count, h + charset.count + glyphs.count), charset, glyphs, priv)
    }

    /// CID-keyed: glyphs .notdef, CID 10 (square, FD 0: nominal 500), CID 11 (curve, FD 1: default 350, nominal 700, local subr)
    /// and CID 500 (hint mask, FD 1).
    static func cidKeyed(_ topMatrix: [Int]? = nil, _ fdMatrix: [Int]? = nil) -> [UInt8] {
        let charset = concat([0], u16(10), u16(11), u16(500))
        let select = concat([3], u16(2), u16(0), [0], u16(2), [1], u16(4))
        let glyphs = index([14], square, curve, masked)
        let priv0 = dict((20, [250]), (21, [500]))
        let priv1 = concat(dict((20, [350]), (21, [700]), (19, [privateSize])), index(curveSubr))

        func head(_ charsetAt: Int, _ selectAt: Int, _ glyphsAt: Int, _ fdArrayAt: Int) -> [UInt8] {
            let top = dict((1230, [391, 392, 0]), (15, [charsetAt]), (17, [glyphsAt]), (1236, [fdArrayAt]), (1237, [selectAt]))
                + (topMatrix.map { dict((1207, $0)) } ?? [])
            return concat([1, 0, 4, 2], index(text("Cid")), index(top), index(text("Adobe"), text("Identity")), index())
        }

        func fdArray(_ at0: Int, _ at1: Int) -> [UInt8] {
            index(dict((18, [priv0.count, at0])) + (fdMatrix.map { dict((1207, $0)) } ?? []), dict((18, [privateSize, at1])))
        }

        let h = head(0, 0, 0, 0).count
        let selectAt = h + charset.count
        let glyphsAt = selectAt + select.count
        let priv0At = glyphsAt + glyphs.count
        let priv1At = priv0At + priv0.count
        let fdArrayAt = priv1At + priv1.count
        return concat(head(h, selectAt, glyphsAt, fdArrayAt), charset, select, glyphs, priv0, priv1, fdArray(priv0At, priv1At))
    }
}
