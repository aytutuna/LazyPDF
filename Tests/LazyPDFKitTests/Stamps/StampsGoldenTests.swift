import XCTest

// Mirrors windows/LazyPDF.Core.Tests/Stamps/StampsGoldenTests.cs: the same cases. The golden file is written by the Windows
// tests.

final class StampsGoldenTests: XCTestCase {
    func test_stampsOutputIsTheGoldenFile() throws {
        let actual = try StampsGolden.run(try Golden.input("stamps", "stamps-input.txt"))
        // The golden file is long: name the lines that differ before the byte comparison says only that they do.
        let expected = try Golden.input("stamps", "stamps-output.txt").components(separatedBy: "\n")
        let lines = actual.components(separatedBy: "\n")
        var shown = 0
        for i in 0..<min(lines.count, expected.count) where lines[i] != expected[i] && shown < 12 {
            XCTFail("line \(i + 1)\n  expected \(expected[i])\n  actual   \(lines[i])")
            shown += 1
        }
        if lines.count != expected.count { XCTFail("expected \(expected.count) lines, actual \(lines.count)") }
        try Golden.check("stamps", "stamps-output.txt", actual)
    }
}
