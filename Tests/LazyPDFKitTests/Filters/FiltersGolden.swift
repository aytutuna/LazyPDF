import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Filters/FiltersGolden.cs. One line of input is "<op> <words>"; the result is
// what the filters made of the bytes: short results in hex, long ones as their length and an FNV-1a sum. Bytes are
// escaped, filters are names joined by commas and parameters are Key=value pairs joined by commas, the value in PDF
// syntax; "-" is none. A blocks case builds its own deflate stream.
enum FiltersGolden {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("golden").appendingPathComponent("filters")

    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("# ") {
            let words = line.split(separator: " ", omittingEmptySubsequences: false).map { String($0) }
            output += "> \(line)\n< \(try op(words[0], Array(words.dropFirst())))\n"
        }
        return output
    }

    private static func op(_ op: String, _ words: [String]) throws -> String {
        do {
            switch op {
            case "decode":
                return show(try PdfFilters.decode(bytes(words[2]), try filter(words[0]), try parameters(words[1]), PdfFilters.defaultMaxSize))
            case "strict":
                return show(try PdfFilters.decode(bytes(words[0]), try FilterFixtures.parse("/FlateDecode"), nil, PdfFilters.defaultMaxSize, strict: true))
            case "inflate":
                return show(try PdfFilters.inflate(bytes(words[0])))
            case "predict":
                return show(try PdfFilters.predict(bytes(words[1]), try parameters(words[0]) as? PdfDictionary))
            case "codec":
                let decoded = try PdfFilters.decodeToCodec(bytes(words[2]), try filter(words[0]), try parameters(words[1]))
                return "codec=\(decoded.codec ?? "-") parameters=\(decoded.parameters == nil ? "-" : "dictionary") data=\(show(decoded.data))"
            case "file":
                return try file(words)
            case "blocks":
                return show(try PdfFilters.decode(blocks(Int(words[0]) ?? 0, Int(words[1]) ?? 0, words[2]), try FilterFixtures.parse("/FlateDecode"), nil,
                                                  PdfFilters.defaultMaxSize, strict: words[3] == "1"))
            default:
                preconditionFailure("No op \"\(op)\".")
            }
        } catch let error as PdfReadException {
            return "error \(error.problem): \(Golden.escape(error.message))"
        }
    }

    // file <filters> <parameters> <name> <strict 0|1> <flips> <length>
    private static func file(_ words: [String]) throws -> String {
        var data = [UInt8](try Data(contentsOf: folder.appendingPathComponent(words[2])))
        if words[4] != "-" {
            for flip in words[4].split(separator: ",") {
                let parts = flip.split(separator: ":")
                data[Int(parts[0]) ?? 0] ^= UInt8(parts[1], radix: 16) ?? 0
            }
        }
        if words[5] != "-" { data = Array(data[..<(Int(words[5]) ?? 0)]) }
        return show(try PdfFilters.decode(data, try filter(words[0]), try parameters(words[1]), PdfFilters.defaultMaxSize, strict: words[3] == "1"))
    }

    // A raw deflate stream: one fixed block of literals and runs of 258 at distance 1, then the tail. The codes are
    // the fixed ones of RFC 1951 3.2.6.
    private static func blocks(_ literals: Int, _ matches: Int, _ tail: String) -> [UInt8] {
        var bits: [Bool] = []
        func put(_ value: Int, _ count: Int) { for i in 0..<count { bits.append(value >> i & 1 != 0) } }
        func code(_ value: Int, _ count: Int) { for i in stride(from: count - 1, through: 0, by: -1) { bits.append(value >> i & 1 != 0) } }
        put(0, 1)
        put(1, 2)
        for i in 0..<literals { code(0x30 + (i * 7 + 3) % 100, 8) }
        for _ in 0..<matches {
            code(0xC5, 8)
            code(0, 5)
        }
        if tail != "cut" { code(0, 7) }
        var extra: [UInt8] = []
        switch tail {
        case "end":
            put(1, 1)
            put(1, 2)
            code(0, 7)
        case "bad":
            put(1, 1)
            put(3, 2)
        case "badlen":
            put(0, 3)
            extra = [1, 0, 0, 0, UInt8(ascii: "x")]
        default: break
        }
        while bits.count % 8 != 0 { bits.append(false) }
        var result: [UInt8] = []
        for i in stride(from: 0, to: bits.count, by: 8) {
            var b = 0
            for j in 0..<8 where bits[i + j] { b |= 1 << j }
            result.append(UInt8(b))
        }
        return result + extra
    }

    private static func bytes(_ word: String) -> [UInt8] { word == "-" ? [] : Golden.unescape(word) }

    private static func filter(_ word: String) throws -> PdfObject? {
        if word == "-" { return nil }
        let names = word.split(separator: ",").map { "/" + $0 }
        return try FilterFixtures.parse(word.contains(",") ? "[" + names.joined(separator: " ") + "]" : names[0])
    }

    private static func parameters(_ word: String) throws -> PdfObject? {
        if word == "-" { return nil }
        let pairs = word.split(separator: ",").map { "/" + $0.replacingOccurrences(of: "=", with: " ") }
        return try FilterFixtures.parse("<< " + pairs.joined(separator: " ") + " >>")
    }

    private static func show(_ data: [UInt8]) -> String {
        if data.count <= 64 { return Hex.string(data) }
        var sum: UInt32 = 2166136261
        for b in data { sum = (sum ^ UInt32(b)) &* 16777619 }
        return "length=\(data.count) fnv=\(String(format: "%08x", sum))"
    }
}
