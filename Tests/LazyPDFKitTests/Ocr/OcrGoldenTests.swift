import XCTest

// Mirrors windows/LazyPDF.Core.Tests/Ocr/OcrGoldenTests.cs: the same cases. The golden file is written by the Windows
// tests.

final class OcrGoldenTests: XCTestCase {
    func test_ocrOutputIsTheGoldenFile() throws {
        let actual = try OcrGolden.run(try Golden.input("ocr", "ocr-input.txt"))
        // The golden file is long: name the lines that differ before the byte comparison says only that they do.
        let expected = try Golden.input("ocr", "ocr-output.txt").components(separatedBy: "\n")
        let lines = actual.components(separatedBy: "\n")
        var shown = 0
        for i in 0..<min(lines.count, expected.count) where lines[i] != expected[i] && shown < 12 {
            XCTFail("line \(i + 1)\n  expected \(expected[i].prefix(600))\n  actual   \(lines[i].prefix(600))")
            shown += 1
        }
        if lines.count != expected.count { XCTFail("expected \(expected.count) lines, actual \(lines.count)") }
        if shown == 0 && lines.count == expected.count { try Golden.check("ocr", "ocr-output.txt", actual) }
    }
}
