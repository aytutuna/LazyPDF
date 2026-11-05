import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FieldDetectorTests.cs: the same cases, and a cancelled task, which stands in for the C#
// CancellationToken of the renderer overload.

final class FieldDetectorTests: XCTestCase {
    private static let page = """
        BT /F1 12 Tf 50 700 Td (Name:) Tj ET
        0.5 w 100 698 m 300 698 l S
        BT /F1 12 Tf 50 650 Td (Address: ____________) Tj ET
        50 600 10 10 re S
        BT /F1 12 Tf 66 601 Td (I agree) Tj ET
        BT /F1 12 Tf 50 560 Td (Code) Tj ET
        100 550 14 18 re S 114 550 14 18 re S 128 550 14 18 re S 142 550 14 18 re S 156 550 14 18 re S 170 550 14 18 re S
        BT /F1 12 Tf 50 500 Td (Phone:) Tj ET
        61 455 m 61 458.314 58.314 461 55 461 c 51.686 461 49 458.314 49 455 c 49 451.686 51.686 449 55 449 c 58.314 449 61 451.686 61 455 c h S
        BT /F1 12 Tf 66 452 Td (Choice) Tj ET
        0.8 g 50 380 100 20 re f 0 g
        BT /F1 12 Tf 300 300 Td (Printed text) Tj ET
        300 298 m 420 298 l S
        50 200 m 250 200 l S 50 200 m 50 230 l S 250 200 m 250 230 l S
        """

    private func open(_ content: String, _ widgets: String = "") throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [" + (widgets.isEmpty ? "" : "6 0 R") + "] /DA (/Helv 0 Tf 0 g)>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [\(widgets.isEmpty ? "" : "6 0 R")]>>")
        pdf.stream(4, "", content)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        if !widgets.isEmpty { pdf.obj(6, widgets) }
        return try PdfDocument.open(pdf.finish())
    }

    private func detect(_ content: String, _ widgets: String = "") throws -> [FieldProposal] {
        FieldDetector.detect(try open(content, widgets), 0)
    }

    private func single(_ found: [FieldProposal], _ match: (FieldProposal) -> Bool, file: StaticString = #filePath, line: UInt = #line) throws -> FieldProposal {
        let hits = found.filter(match)
        XCTAssertEqual(hits.count, 1, file: file, line: line)
        return try XCTUnwrap(hits.first, file: file, line: line)
    }

    func test_ruledLinesUnderscoresBoxesAndColonGapsAreProposed() throws {
        let found = try detect(Self.page)

        let line = try single(found) { $0.label == "Name" }
        XCTAssertEqual(line.kind, .text)
        XCTAssertEqual(line.rect.left, 100, accuracy: 0.5)
        XCTAssertEqual(line.rect.right, 300, accuracy: 0.5)
        XCTAssertTrue(line.rect.bottom >= 698 && line.rect.bottom <= 700)

        let underscores = try single(found) { $0.label == "Address" }
        XCTAssertEqual(underscores.kind, .text)
        XCTAssertTrue(underscores.rect.width > 60)

        let check = try single(found) { $0.kind == .checkBox }
        XCTAssertEqual(check.label, "I agree")
        XCTAssertEqual(check.rect, PdfRect(50, 600, 60, 610))

        let comb = try single(found) { $0.cells > 0 }
        XCTAssertEqual(comb.cells, 6)
        XCTAssertEqual(comb.label, "Code")
        XCTAssertEqual(comb.rect, PdfRect(100, 550, 184, 568))

        let phone = try single(found) { $0.label == "Phone" }
        XCTAssertEqual(phone.kind, .text)
        XCTAssertTrue(phone.rect.left > 80 && phone.rect.width >= 100)

        let radio = try single(found) { $0.kind == .radio }
        XCTAssertEqual(radio.label, "Choice")
        XCTAssertEqual(radio.rect.width, 12, accuracy: 0.5)
    }

    func test_filledBlanksBarsAndClosedCellsAreNotProposed() throws {
        let found = try detect(Self.page)

        XCTAssertFalse(found.contains { $0.rect.left >= 295 && $0.rect.bottom > 290 && $0.rect.bottom < 330 })
        XCTAssertFalse(found.contains { $0.rect.bottom > 370 && $0.rect.bottom < 410 })
        XCTAssertFalse(found.contains { $0.rect.bottom > 190 && $0.rect.bottom < 240 })
        XCTAssertEqual(found.count, 6)
    }

    func test_existingFieldsAreNotProposedAgainAndNamesAreUnique() throws {
        let widget = "<</Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [100 699 300 715] /P 3 0 R>>"

        let found = try detect(Self.page, widget)

        XCTAssertFalse(found.contains { $0.label == "Name" })
        let again = try detect("BT /F1 12 Tf 50 700 Td (Name:) Tj ET 100 698 m 300 698 l S BT /F1 12 Tf 50 650 Td (Name:) Tj ET 100 648 m 300 648 l S")
        XCTAssertEqual(again.map { $0.name }, ["Name", "Name2"])
    }

    func test_proposalsAreAcceptedByAddingThemAsFields() throws {
        let document = try open(Self.page)
        let form = PdfForm.read(document)
        let proposals = FieldDetector.detect(document)

        for p in proposals { try form.addField(p.toSpec()) }

        XCTAssertEqual(form.fields.count, proposals.count)
        XCTAssertEqual(form.find("Code")?.maxLength, 6)
        XCTAssertTrue(try XCTUnwrap(form.find("Code")).has(.comb))
        XCTAssertEqual(PdfForm.read(try AnnotationFixtures.reopen(document)).fields.map { $0.name }.sorted(), proposals.map { $0.name }.sorted())
        XCTAssertTrue(FieldDetector.detect(document).isEmpty)
    }

    func test_pagesWithoutVectorContentGiveNothing() throws {
        XCTAssertTrue(FieldDetector.detect(try AnnotationFixtures.blank(), 0).isEmpty)
        XCTAssertTrue(try detect("BT /F1 12 Tf 50 700 Td (Just a sentence on the page.) Tj ET").isEmpty)
    }

    func test_brokenContentDoesNotThrow() throws {
        XCTAssertTrue(try detect("q q q Q Q Q Q ) ] >> BT (x) Tj").isEmpty)
    }

    private final class NoRenderer: PageRenderer {
        func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
    }

    func test_detectingOnACancelledTaskStopsAtThePage() async throws {
        let document = try AnnotationFixtures.blank()
        let task = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            return try FieldDetector.detect(document, NoRenderer()).count
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }
}
