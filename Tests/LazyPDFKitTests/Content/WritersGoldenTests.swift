import XCTest

// Mirrors windows/LazyPDF.Core.Tests/Content/WritersGoldenTests.cs. The golden file is written by the Windows tests.
final class WritersGoldenTests: XCTestCase {
    func test_writersOutputIsTheGoldenFile() throws {
        let actual = try WritersGolden.run(try ShapingGolden.font(), try Golden.input("writers", "writers-input.txt"))
        let expected = try Golden.input("writers", "writers-output.txt").components(separatedBy: "\n")
        let lines = actual.components(separatedBy: "\n")
        var shown = 0
        for i in 0..<min(lines.count, expected.count) where lines[i] != expected[i] && shown < 8 {
            XCTFail("line \(i + 1)\n  expected \(expected[i])\n  actual   \(lines[i])")
            shown += 1
        }
        if lines.count != expected.count { XCTFail("expected \(expected.count) lines, actual \(lines.count)") }
        try Golden.check("writers", "writers-output.txt", actual)
    }
}
