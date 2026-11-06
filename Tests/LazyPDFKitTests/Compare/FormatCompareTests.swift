import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/FormatCompareTests.cs: the same cases.

final class FormatCompareTests: CompareTestCase {
    private let middle = "Second line is where the format changes now"

    private func page3(_ middle: CompareLine) -> [[CompareLine]] {
        [[
            CompareLine("First line of the page stays plain and the same"),
            middle,
            CompareLine("Third line also stays exactly as it was before"),
        ]]
    }

    private func run(_ before: [[CompareLine]], _ after: [[CompareLine]]) throws -> ComparisonResult {
        let a = try doc(before)
        let b = try doc(after)
        return try PdfComparer.compare(a, b)
    }

    func test_fontChangeOnlyIsOneFormatChangeAndNoTextChange() throws {
        let result = try run(page3(CompareLine(middle)), page3(CompareLine(middle, font: "F2")))
        let change = try single(result.changes)
        XCTAssertEqual(change.kind, .changed)
        XCTAssertEqual(change.area, .format)
        XCTAssertEqual(change.oldText, middle)
        XCTAssertEqual(change.newText, middle)
        let detail = try XCTUnwrap(change.detail)
        XCTAssertTrue(detail.contains("Helvetica"))
        XCTAssertTrue(detail.contains("Times"))
        _ = try single(change.oldQuads)
        _ = try single(change.newQuads)
        XCTAssertEqual(result.summary.format, 1)
        XCTAssertEqual(result.summary.text, 0)
    }

    func test_sizeChangeIsFormatOnly() throws {
        let change = try single(try run(page3(CompareLine(middle)), page3(CompareLine(middle, size: 14))).changes)
        XCTAssertEqual(change.area, .format)
        let detail = try XCTUnwrap(change.detail)
        XCTAssertTrue(detail.contains("12"))
        XCTAssertTrue(detail.contains("14"))
    }

    func test_colourChangeIsFormatOnly() throws {
        let change = try single(try run(page3(CompareLine(middle)), page3(CompareLine(middle, color: "1 0 0"))).changes)
        XCTAssertEqual(change.area, .format)
        XCTAssertTrue(try XCTUnwrap(change.detail).contains("#FF0000"))
    }

    func test_oneWordInAnotherFontIsJustThatWord() throws {
        let before = [[CompareLine("alpha beta gamma delta epsilon zeta eta theta iota kappa")]]
        let file = TestPdf.text(bytes(before)).replacingOccurrences(
            of: "(alpha beta gamma delta epsilon zeta eta theta iota kappa) Tj",
            with: "(alpha beta gamma delta ) Tj /F3 12 Tf (epsilon) Tj /F1 12 Tf ( zeta eta theta iota kappa) Tj")
        let a = try doc(before)
        let b = try open(TestPdf.latin(file))
        let change = try single(try PdfComparer.compare(a, b).changes)
        XCTAssertEqual(change.area, .format)
        XCTAssertEqual(change.oldText, "epsilon")
    }

    func test_formatAndTextChangesAreReportedSeparately() throws {
        let result = try run(page3(CompareLine(middle)), page3(CompareLine("Second line is where the layout changes now", font: "F2")))
        XCTAssertEqual(result.summary.text, 1)
        XCTAssertEqual(result.summary.format, 2)
        XCTAssertEqual(try single(result.changes, where: { $0.area == .text }).oldText, "format")
    }

    func test_subsetTagOfTheSameFontIsNotAChange() throws {
        let pdf = bytes(page3(CompareLine(middle)))
        let tagged = TestPdf.text(pdf).replacingOccurrences(of: "/BaseFont /Helvetica ", with: "/BaseFont /ABCDEF+Helvetica ")
        let a = try open(pdf)
        let b = try open(TestPdf.latin(tagged))
        XCTAssertTrue(try PdfComparer.compare(a, b).isIdentical)
    }
}
