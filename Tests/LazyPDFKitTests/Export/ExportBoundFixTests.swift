import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/ExportBoundFixTests.cs: the same cases. The C# regular expression that reads the
// cell edges out of the RTF is a scan for \cellx and its digits.

final class ExportBoundFixTests: XCTestCase {
    private func cell(_ text: String, _ x: Double, _ y: Double) -> ExLine {
        ExLine(box: DisplayRect(x, y, 40, 10), runs: [ExportRun(text, false, false, 10)], size: 10, allBold: false, before: .tab, block: 0)
    }

    private func row(_ cells: ExLine...) -> ExRow {
        let row = ExRow()
        row.cells = cells
        return row
    }

    private func onePage(_ blocks: [ExportBlock], _ lines: [ExportTextLine] = []) -> ExportDocument {
        ExportDocument(nil, [ExportPage(0, 612, 792, blocks, lines, [])], 11)
    }

    private func paragraphs(_ count: Int, _ length: Int) -> ExportDocument {
        let paragraph = ExportParagraph(DisplayRect(10, 10, 500, 20), [ExportRun(String(repeating: "x", count: length), false, false, 11)])
        return onePage([ExportBlock](repeating: paragraph, count: count))
    }

    private func cellEdges(_ rtf: String) -> [Int] {
        rtf.components(separatedBy: #"\cellx"#).dropFirst().compactMap { Int($0.prefix { $0.isASCII && $0.isNumber }) }
    }

    private func assertTooLarge(_ expression: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertTrue(error is PdfReadException, "\(error)", file: file, line: line)
        }
    }

    func test_staggeredCellsDoNotBecomeAMostlyBlankTable() {
        var rows: [ExRow] = []
        for i in 0..<40 {
            let y = Double(10 * i)
            rows.append(row(cell("a", Double(200 * i), y), cell("b", Double(200 * i + 100), y)))
        }
        rows.append(row(cell("p", 0, 400), cell("q", 100, 400), cell("r", 200, 400)))
        XCTAssertNil(ExportFlow.aligned(rows))
    }

    func test_columnsWithSomeBlankCellsStayATable() throws {
        let rows = [
            row(cell("a", 0, 0), cell("b", 100, 0), cell("c", 200, 0)),
            row(cell("d", 0, 10), cell("e", 200, 10)),
            row(cell("f", 0, 20), cell("g", 100, 20), cell("h", 200, 20)),
        ]
        let table = try XCTUnwrap(ExportFlow.aligned(rows))
        XCTAssertEqual(table.rows[1], ["d", "", "e"])
    }

    func test_picturesCountAgainstTheAnalysisBudget() throws {
        let document = try ExportKit.open(String(repeating: "q 20 0 0 20 100 100 cm /Im1 Do Q ", count: 400))
        XCTAssertThrowsError(try ExportLayout.analyze(document, [Int](repeating: 0, count: 3000))) { error in
            XCTAssertEqual((error as? PdfReadException)?.message, ExportText.tooLarge)
        }
    }

    func test_aLongLedgerOfShortCellsIsStillExported() throws {
        var content = ""
        for r in 0..<100 {
            for c in 0..<8 { content += "BT /F1 5 Tf \(20 + 70 * c) \(780 - 7 * r) Td (Cell\(String(format: "%02d", r % 100))) Tj ET\n" }
        }
        let document = try ExportKit.open(content)
        XCTAssertEqual(try ExportLayout.analyze(document, [Int](repeating: 0, count: 2400)).pages.count, 2400)
    }

    func test_slidesAreRefusedOnceTheirMarkupPassesTheLimit() {
        let picture = ExportPicture(DisplayRect(10, 10, 20, 20), ExportImage([UInt8](repeating: 0, count: 8), true, 8, 6))
        let page = ExportPage(0, 612, 792, [], [], [ExportPicture](repeating: picture, count: 400))
        let document = ExportDocument(nil, [ExportPage](repeating: page, count: 700), 11)
        assertTooLarge(try PptxWriter.make(document))
    }

    func test_moreSlidesThanAPackageCanHoldAreRefused() {
        let page = ExportPage(0, 612, 792, [], [], [])
        let document = ExportDocument(nil, [ExportPage](repeating: page, count: 33000), 11)
        assertTooLarge(try PptxWriter.make(document))
    }

    func test_fixedHtmlChecksTheLengthAsLinesAreWritten() {
        let line = ExportTextLine(DisplayRect(10, 10, 100, 10), [ExportRun(String(repeating: "&", count: 100), false, false, 11)])
        let document = onePage([], [ExportTextLine](repeating: line, count: 1_200_000))
        assertTooLarge(try HtmlWriter.fixed(document))
    }

    func test_markdownChecksTheLengthOfWhatTheLastBlockAdded() {
        assertTooLarge(try MarkdownWriter.make(paragraphs(537, 1_000_000)))
    }

    func test_plainTextChecksTheLengthBeforeTheLastToString() {
        assertTooLarge(try PlainTextWriter.make(paragraphs(537, 1_000_000)))
    }

    func test_plainTextBelowTheLimitIsWritten() throws {
        let text = try PlainTextWriter.make(paragraphs(3, 1000))
        XCTAssertEqual(text.utf16.count, 3 * 1002 + 1)
    }

    func test_docxBlankCellsOfOneTableCountAgainstTheLimit() {
        let blank = [String](repeating: "", count: 63)
        let table = ExportTable(DisplayRect(10, 10, 500, 20), [[String]](repeating: blank, count: 150_000), nil, true)
        assertTooLarge(try DocxWriter.make(onePage([table])))
    }

    func test_anRtfTableOverTheColumnLimitGivesTheLastCellTheWidthOfTheColumnsItHolds() throws {
        let row = (0..<70).map { "c\($0)" }
        let table = ExportTable(DisplayRect(10, 10, 500, 20), [row], [Double](repeating: 10, count: 70), true)
        let edges = cellEdges(try RtfWriter.make(onePage([table])))
        XCTAssertEqual(edges.count, 63)
        let first = edges[0], last = edges[62] - edges[61]
        XCTAssertTrue(last >= 8 * first - 8 && last <= 8 * first + 8, "\(first) \(last)")
    }

    func test_anRtfTableWithoutWidthsSharesTheSameWay() throws {
        let row = (0..<70).map { "c\($0)" }
        let table = ExportTable(DisplayRect(10, 10, 500, 20), [row], nil, false)
        let edges = cellEdges(try RtfWriter.make(onePage([table])))
        let last = edges[62] - edges[61]
        XCTAssertTrue(last >= 8 * edges[0] - 8 && last <= 8 * edges[0] + 8, "\(edges[0]) \(last)")
    }
}
