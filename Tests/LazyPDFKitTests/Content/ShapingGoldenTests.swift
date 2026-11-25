import XCTest

// Mirrors windows/LazyPDF.Core.Tests/Content/ShapingGoldenTests.cs: the same cases. The font and the golden file are
// written by the Windows tests.

final class ShapingGoldenTests: XCTestCase {
    func test_linesAreTheGoldenFile() throws {
        let actual = try ShapingGolden.dump(try ShapingGolden.font(), try Golden.input("shaping", "lines-input.txt"))
        // Name the lines that differ before the byte comparison says only that they do.
        let expected = try Golden.input("shaping", "lines-output.txt").components(separatedBy: "\n")
        let lines = actual.components(separatedBy: "\n")
        var shown = 0
        for i in 0..<min(lines.count, expected.count) where lines[i] != expected[i] && shown < 12 {
            XCTFail("line \(i + 1)\n  expected \(expected[i])\n  actual   \(lines[i])")
            shown += 1
        }
        try Golden.check("shaping", "lines-output.txt", actual)
    }
}
