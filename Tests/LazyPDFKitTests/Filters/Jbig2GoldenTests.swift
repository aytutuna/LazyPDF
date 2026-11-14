import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/Jbig2GoldenTests.cs. The streams and the input are made by the encoders of the
// Windows tests; this side only reads them. One line of input is "jbig2 <file> <globals> <flips> <length> <fit>" (fit is
// /Width and /Height of the image as WxH); the result is the page the filter returns: short results in hex, long ones as
// their length and an FNV-1a sum.
final class Jbig2GoldenTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("golden").appendingPathComponent("filters")

    func test_outputIsTheGoldenFile() throws {
        let actual = Self.run(try Golden.input("filters", "jbig2-input.txt"))
        let expected = try Golden.input("filters", "jbig2-output.txt").components(separatedBy: "\n")
        let lines = actual.components(separatedBy: "\n")
        var shown = 0
        for i in 0..<min(lines.count, expected.count) where lines[i] != expected[i] && shown < 12 {
            XCTFail("line \(i + 1), after \(i > 0 ? lines[i - 1] : "")\n  expected \(expected[i])\n  actual   \(lines[i])")
            shown += 1
        }
        try Golden.check("filters", "jbig2-output.txt", actual)
    }

    private static func run(_ input: String) -> String {
        var output = ""
        for line in input.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("# ") {
            let words = line.split(separator: " ", omittingEmptySubsequences: false).map { String($0) }
            output += "> \(line)\n< \(op(Array(words.dropFirst())))\n"
        }
        return output
    }

    private static func parameters(_ globals: [UInt8]) -> PdfDictionary {
        let parameters = PdfDictionary()
        parameters["JBIG2Globals"] = PdfStream(PdfDictionary(), data: globals)
        return parameters
    }

    // jbig2 <file> <globals> <flips> <length> <fit>
    private static func op(_ words: [String]) -> String {
        do {
            var data = [UInt8](try Data(contentsOf: folder.appendingPathComponent(words[0])))
            if words[2] != "-" {
                for flip in words[2].split(separator: ",") {
                    let parts = flip.split(separator: ":")
                    data[Int(parts[0])!] ^= UInt8(parts[1], radix: 16)!
                }
            }
            if words[3] != "-" { data = Array(data[..<Int(words[3])!]) }
            let p = words[1] == "-" ? PdfDictionary() : parameters([UInt8](try Data(contentsOf: folder.appendingPathComponent(words[1]))))
            if words[4] != "-" {
                let size = words[4].split(separator: "x")
                p["Width"] = PdfNumber(Int(size[0])!)
                p["Height"] = PdfNumber(Int(size[1])!)
            }
            return show(try PdfFilters.decode(data, PdfName("JBIG2Decode"), p, PdfFilters.defaultMaxSize))
        } catch let error as PdfReadException {
            return "error \(error.problem): \(Golden.escape(error.message))"
        } catch {
            return "error \(error)"
        }
    }

    private static func show(_ data: [UInt8]) -> String {
        if data.count <= 64 { return Hex.string(data) }
        var sum: UInt32 = 2166136261
        for b in data { sum = (sum ^ UInt32(b)) &* 16777619 }
        return "length=\(data.count) fnv=\(String(format: "%08x", sum))"
    }
}
