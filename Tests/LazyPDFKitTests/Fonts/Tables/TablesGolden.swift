import Foundation
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Fonts/Tables/TablesGolden.cs. One case per input line:
// "<codeBytes> pairs <code>=<UTF-16BE hex> ...", "<codeBytes> many <count>" (codes 0, 2, 4, ... with a
// letter and a CJK character, so every section is a bfchar) or "<codeBytes> spans <count>" (pairs of codes
// that do not join, so every section is a bfrange). The dump is the written stream after the line it came from.
enum TablesGolden {
    private static func text(_ hex: Substring) -> String {
        var units: [UInt16] = []
        var rest = hex
        while !rest.isEmpty {
            units.append(UInt16(rest.prefix(4), radix: 16) ?? 0)
            rest = rest.dropFirst(4)
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func unit(_ value: Int) -> String {
        String(decoding: [UInt16(value)], as: UTF16.self)
    }

    private static func pairs(_ parts: [Substring]) -> [(key: Int, value: String)] {
        parts.dropFirst(2).map { part in
            let halves = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let code = Int(Int32(bitPattern: UInt32(halves[0], radix: 16) ?? 0))
            return (code, text(halves[1]))
        }
    }

    private static func many(_ count: Int) -> [(key: Int, value: String)] {
        (0..<count).map { ($0 * 2, "x" + unit(0x4E00 + $0 * 3)) }
    }

    private static func spans(_ count: Int) -> [(key: Int, value: String)] {
        var map: [(key: Int, value: String)] = []
        for i in 0..<count {
            map.append((i * 0x10, unit(0x4E00 + i * 3)))
            map.append((i * 0x10 + 1, unit(0x4E00 + i * 3 + 1)))
        }
        return map
    }

    static func toUnicode(_ input: String) throws -> String {
        var out = ""
        for line in input.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            let codeBytes = Int(parts[0]) ?? 0
            let map: [(key: Int, value: String)]
            switch parts[1] {
            case "pairs": map = pairs(parts)
            case "many": map = many(Int(parts[2]) ?? 0)
            default: map = spans(Int(parts[2]) ?? 0)
            }
            out += "== \(line)\n"
            out += String(decoding: try ToUnicodeCMap.write(map, codeBytes: codeBytes), as: UTF8.self)
        }
        return out
    }
}
