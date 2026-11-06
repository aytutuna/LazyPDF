import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactShiftRunTests.cs: the same cases. A removed run keeps no trace of the
// width of single characters, whatever sits between the shows; the small cases around it.

final class RedactShiftRunTests: XCTestCase {
    private func redact(_ document: PdfDocument, _ word: String) throws -> PdfDocument {
        let result = try PdfRedactor(document).apply([try RedactionKit.markOf(document, 0, word)])
        return try RedactionKit.open(result)
    }

    private func shifts(_ document: PdfDocument) -> Int {
        ContentParser.parse(document.pages[0].contents()).filter { $0.operator == "TJ" }
            .reduce(0) { $0 + (($1.operands.last as? PdfArray)?.items.filter { $0 is PdfNumber }.count ?? 0) }
    }

    private func count(_ document: PdfDocument, _ name: String) -> Int {
        ContentParser.parse(document.pages[0].contents()).filter { $0.operator == name }.count
    }

    private func assertOneShift(_ content: String, _ resources: String = "") throws {
        let document = try RedactionKit.page(content, resources, ["<</Type /ExtGState /CA 1>>"])
        let output = try redact(document, "John")
        XCTAssertEqual(shifts(output), 1)
        XCTAssertEqual(RedactionKit.text(output).trimmingCharacters(in: .whitespaces), "tail")
    }

    func test_repeatedGraphicsStateBetweenShowsKeepsNoWidthPerShow() throws {
        try assertOneShift("BT /F1 12 Tf 50 700 Td (J) Tj /G0 gs (o) Tj /G0 gs (h) Tj /G0 gs (n) Tj ( tail) Tj ET", "/ExtGState <</G0 6 0 R>>")
    }

    func test_saveAndRestoreInsideATextObjectMakesThePagePicture() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td q (J) Tj Q q (o) Tj Q q (h) Tj Q q (n) Tj Q ( tail) Tj ET")
        try RedactionKit.assertFlattened(document, [try RedactionKit.markOf(document, 0, "John")], "John")
    }

    func test_unchangedHorizontalScaleBetweenShowsKeepsNoWidthPerShow() throws {
        try assertOneShift("BT /F1 12 Tf 50 700 Td 100 Tz (J) Tj 100 Tz (o) Tj 100 Tz (h) Tj 100 Tz (n) Tj ( tail) Tj ET")
    }

    func test_otherFontAtTheSameSizeBetweenShowsKeepsNoWidthPerShow() throws {
        let document = try ContentTestPdf.page("BT /F1 12 Tf 50 700 Td (J) Tj /F2 12 Tf (o) Tj /F1 12 Tf (h) Tj /F2 12 Tf (n) Tj ( tail) Tj ET",
                                               "/Font <</F1 5 0 R /F2 5 0 R>>", [RedactionKit.helvetica])
        let output = try redact(document, "John")
        XCTAssertEqual(shifts(output), 1)
    }

    func test_changedHorizontalScaleStopsTheShift() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td (J) Tj (o) Tj (h) Tj (n) Tj 50 Tz ( tail) Tj ET")
        let output = try redact(document, "John")
        XCTAssertEqual(shifts(output), 1)
    }

    func test_matrixUndoneByItsInverseAroundARemovedShowIsDropped() throws {
        var x = 106.0
        var content = ""
        for (letter, width) in [("J", 500), ("o", 556), ("h", 556), ("n", 556)] {
            content += "1 0 0 1 \(PdfNumber(x).text) 700 cm BT /F1 12 Tf (\(letter)) Tj ET 1 0 0 1 -\(PdfNumber(x).text) -700 cm "
            x += Double(width) * 12 / 1000.0
        }
        content += "BT /F1 12 Tf 300 300 Td (tail) Tj ET"
        let document = try RedactionKit.page(content)
        let output = try redact(document, "John")
        XCTAssertEqual(count(output, "cm"), 0)
    }

    func test_moveWithALeadingBeforeAMoveWithoutOneIsMerged() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td (J) Tj 6 0 TD (o) Tj 6.672 0 Td (h) Tj 6.672 0 Td (n) Tj ET")
        let output = try redact(document, "John")
        XCTAssertEqual(count(output, "TD"), 0)
    }

    func test_leadingOfAMoveThatGoesIsKept() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td (Name: ) Tj 0 -14 TD (John) Tj ET")
        let output = try redact(document, "John")
        XCTAssertEqual(count(output, "TD"), 0)
        XCTAssertTrue(ContentParser.parse(output.pages[0].contents()).contains { $0.operator == "TL" && $0.number(0) == 14 })
    }

    func test_propertyListOfTheEnclosingStreamSeenFromAFormWithResourcesOfItsOwnMakesThePagePicture() throws {
        let document = try RedactionKit.page("/Fm Do", "/Properties <</P0 <</Alt (ZQXDESCR)>>>> /XObject <</Fm 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "/Span /P0 BDC BT /F1 12 Tf 100 100 Td (xyzw) Tj ET EMC")
        }
        try RedactionKit.assertFlattened(document, PdfRect(90, 90, 200, 120), "ZQXDESCR")
    }

    func test_glyphTooSmallForTheOldThresholdsStillMeetsTheMark() throws {
        let document = try RedactionKit.page("BT /F1 0.0002 Tf 100 100 Td (ZQXTINY) Tj ET")
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(50, 50, 150, 150))])
        XCTAssertEqual(result.report.glyphs, 7)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXTINY"))
    }
}
