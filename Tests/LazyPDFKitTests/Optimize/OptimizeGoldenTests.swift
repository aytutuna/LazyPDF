import XCTest

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeGoldenTests.cs: the same cases. The golden file is written by the
// Windows tests.

final class OptimizeGoldenTests: XCTestCase {
    func test_optimizeOutputIsTheGoldenFile() throws {
        let actual = try OptimizeGolden.run(try Golden.input("optimize", "optimize-input.txt"))
        // A linearized file is one long line: name the first byte that differs before the byte comparison says only that it does.
        let expected = try Golden.input("optimize", "optimize-output.txt").components(separatedBy: "\n")
        let lines = actual.components(separatedBy: "\n")
        for i in 0..<min(lines.count, expected.count) where lines[i] != expected[i] {
            let a = Array(lines[i].utf8), e = Array(expected[i].utf8)
            let at = (0..<min(a.count, e.count)).first { a[$0] != e[$0] } ?? min(a.count, e.count)
            let from = max(0, at - 40)
            XCTFail("line \(i + 1) differs at byte \(at)\n  expected \(String(decoding: e[from..<min(e.count, at + 40)], as: UTF8.self))\n  actual   \(String(decoding: a[from..<min(a.count, at + 40)], as: UTF8.self))")
        }
        try Golden.check("optimize", "optimize-output.txt", actual)
    }
}
