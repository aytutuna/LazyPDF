import XCTest

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/PdfUaGoldenTests.cs: the same cases. The golden file is written by the Windows
// tests.

final class PdfUaGoldenTests: XCTestCase {
    func test_pdfUaOutputIsTheGoldenFile() throws {
        let actual = try PdfUaGolden.run(try Golden.input("pdfua", "pdfua-input.txt"))
        let expected = try Golden.input("pdfua", "pdfua-output.txt").components(separatedBy: "\n")
        let lines = actual.components(separatedBy: "\n")
        var shown = 0
        for i in 0..<min(lines.count, expected.count) where lines[i] != expected[i] && shown < 12 {
            XCTFail("line \(i + 1)\n  expected \(expected[i])\n  actual   \(lines[i])")
            shown += 1
        }
        if lines.count != expected.count { XCTFail("expected \(expected.count) lines, actual \(lines.count)") }
        try Golden.check("pdfua", "pdfua-output.txt", actual)
    }
}
