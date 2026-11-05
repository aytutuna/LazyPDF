import XCTest

// Mirrors windows/LazyPDF.Core.Tests/Filters/FiltersGoldenTests.cs: the same cases. The golden file is written by
// the Windows tests; the binary inputs beside it are made by zlib and by hand.

final class FiltersGoldenTests: XCTestCase {
    func test_filtersOutputIsTheGoldenFile() throws {
        let actual = try FiltersGolden.run(try Golden.input("filters", "filters-input.txt"))
        // The golden file is long: name the lines that differ before the byte comparison says only that they do.
        let expected = try Golden.input("filters", "filters-output.txt").components(separatedBy: "\n")
        let lines = actual.components(separatedBy: "\n")
        var shown = 0
        for i in 0..<min(lines.count, expected.count) where lines[i] != expected[i] && shown < 12 {
            XCTFail("line \(i + 1), after \(i > 0 ? lines[i - 1] : "")\n  expected \(expected[i])\n  actual   \(lines[i])")
            shown += 1
        }
        if lines.count != expected.count { XCTFail("expected \(expected.count) lines, actual \(lines.count)") }
        try Golden.check("filters", "filters-output.txt", actual)
    }
}
