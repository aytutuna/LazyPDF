import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/ExportOutputBudgetTests.cs: the same cases.

final class ExportOutputBudgetTests: XCTestCase {
    private func onePage(_ blocks: [ExportBlock]) -> ExportDocument {
        ExportDocument(nil, [ExportPage(0, 612, 792, blocks, [], [])], 11)
    }

    private func pictures(_ count: Int, _ bytes: Int) -> [ExportBlock] {
        let picture = ExportPicture(DisplayRect(10, 10, 8, 6), ExportImage([UInt8](repeating: 0, count: bytes), true, 8, 6))
        return [ExportBlock](repeating: picture, count: count)
    }

    func test_docxMarkupOfManyPicturesIsRefusedBeforeTheStringIsBuilt() {
        let document = onePage(pictures(750_000, 30))
        XCTAssertThrowsError(try DocxWriter.make(document)) { XCTAssertTrue($0 is PdfReadException) }
    }

    func test_htmlMarkupAroundSmallPicturesCountsAgainstTheLimit() {
        let document = onePage(pictures(5_000_000, 30))
        XCTAssertThrowsError(try HtmlWriter.reflowed(document)) { XCTAssertTrue($0 is PdfReadException) }
    }

    func test_rtfEscapesOfTextCountAgainstTheLimit() {
        let paragraph = ExportParagraph(DisplayRect(10, 10, 500, 20), [ExportRun(String(repeating: "\u{AC00}", count: 60 << 20), false, false, 11)])
        XCTAssertThrowsError(try RtfWriter.make(onePage([paragraph]))) { XCTAssertTrue($0 is PdfReadException) }
    }

    func test_manySmallRunsPassTheAnalysisBudget() throws {
        var content = "BT /F1 4 Tf "
        for i in 0..<20000 { content += "1 0 0 1 \(10 + i % 50 * 11) \(780 - Double(i / 50) * 1.5) Tm (x) Tj " }
        content += "ET"
        let document = try ExportKit.open(content)
        XCTAssertEqual(try ExportLayout.analyze(document, [Int](repeating: 0, count: 60)).pages.count, 60)
    }
}
