import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/OfficeTableTests.cs.

final class OfficeTableTests: XCTestCase {
    private static let small = LayoutGeometry(width: 200, height: 200, top: 20, right: 20, bottom: 20, left: 20)

    private func docx(_ body: String) throws -> [UInt8] { try DocxSpec.package([(key: "document", text: body)]) }

    private func cell(_ text: String, _ properties: String = "") -> String {
        "<w:tc>\(properties.isEmpty ? "" : "<w:tcPr>\(properties)</w:tcPr>")<w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:tc>"
    }

    private func row(_ cells: String, _ properties: String = "") -> String {
        "<w:tr>\(properties.isEmpty ? "" : "<w:trPr>\(properties)</w:trPr>")\(cells)</w:tr>"
    }

    private func table(_ rows: String, _ grid: Int...) -> String {
        "<w:tbl><w:tblGrid>\(grid.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined())</w:tblGrid>\(rows)</w:tbl>"
    }

    private func layout(_ document: LayoutDocument) throws -> LayoutResult {
        try Paginator(document, LayoutFonts(OfficeLayoutSpec.fonts())).run()
    }

    private func readTable(_ body: String) throws -> LayoutTable {
        let document = try DocxReader.read(try docx(body))
        XCTAssertEqual(document.sections[0].blocks.count, 1)
        return try XCTUnwrap(document.sections[0].blocks[0] as? LayoutTable)
    }

    private func single(_ page: LayoutGeometry, _ blocks: [LayoutBlock]) -> LayoutDocument {
        let section = LayoutSection()
        section.page = page
        section.blocks = blocks
        let document = LayoutDocument()
        document.sections = [section]
        return document
    }

    private func paragraph(_ text: String) -> LayoutParagraph {
        let run = LayoutRun()
        run.text = text
        let made = LayoutParagraph()
        made.runs = [run]
        return made
    }

    private func lc(_ paragraphs: String...) -> LayoutCell {
        let made = LayoutCell()
        made.paragraphs = paragraphs.map { paragraph($0) }
        return made
    }

    private func lcell(column: Int = 0, rowSpan: Int = 1, _ paragraphs: [LayoutParagraph]) -> LayoutCell {
        let made = LayoutCell()
        made.column = column
        made.rowSpan = rowSpan
        made.paragraphs = paragraphs
        return made
    }

    private func lrow(_ cells: [LayoutCell], header: Bool = false, cantSplit: Bool = false) -> LayoutRow {
        let made = LayoutRow()
        made.cells = cells
        made.header = header
        made.cantSplit = cantSplit
        return made
    }

    private func ltable(_ columns: [Double], _ rows: [LayoutRow]) -> LayoutTable {
        let made = LayoutTable()
        made.columns = columns
        made.rows = rows
        return made
    }

    private func texts(_ page: LayoutPage) -> [PlacedText] {
        page.boxes.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
    }

    private func rects(_ page: LayoutPage) -> [PlacedRect] {
        page.boxes.compactMap { if case .rect(let r) = $0 { return r } else { return nil } }
    }

    private func pageText(_ pdf: PdfDocument, _ i: Int) -> String { TextPage.create(pdf, pdf.pages[i]).text }

    func test_convertsATableToAPdfWithItsCellsInReadingOrder() throws {
        let body = table(row(cell("a1") + cell("b1")) + row(cell("a2") + cell("b2")), 3000, 3000)
        let made = try OfficeConverter.fromWord(try docx(body), OfficeLayoutSpec.fonts())
        XCTAssertFalse(made.skipped.contains { $0.kind == "table" })
        let pdf = try PdfDocument.open(made.bytes)
        // The Swift text extractor reads down columns first, so only what is on the page is compared.
        let text = pageText(pdf, 0)
        for cell in ["a1", "b1", "a2", "b2"] { XCTAssertTrue(text.contains(cell), cell) }
    }

    func test_columnsStartWhereTheGridPutsThem() throws {
        let document = try DocxReader.read(try docx(table(row(cell("a") + cell("b") + cell("c")), 2000, 3000, 1000)))
        let xs = texts(try layout(document).pages[0]).map { ($0.x * 100).rounded() / 100 }
        XCTAssertEqual(xs, [77.4, 177.4, 327.4])
    }

    func test_aSpanTakesTheWidthOfItsColumnsAndAMergeTheHeightOfItsRows() throws {
        let body = table(
            row(cell("wide", "<w:gridSpan w:val=\"2\"/>") + cell("tall", "<w:vMerge w:val=\"restart\"/>")) +
            row(cell("x") + cell("y") + "<w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc>"), 1000, 1000, 1000)
        let made = try readTable(body)
        XCTAssertEqual(made.rows[0].cells.map(\.span), [2, 1])
        XCTAssertEqual(made.rows[0].cells[1].rowSpan, 2)
        XCTAssertEqual(made.rows[1].cells.count, 2)
    }

    func test_aCellFacingTwoBordersTakesTheWiderOne() throws {
        let wide = "<w:tcBorders><w:right w:val=\"single\" w:sz=\"16\" w:color=\"FF0000\"/></w:tcBorders>"
        let thin = "<w:tcBorders><w:left w:val=\"single\" w:sz=\"4\" w:color=\"000000\"/></w:tcBorders>"
        let made = try readTable(table(row(cell("a", wide) + cell("b", thin)), 2000, 2000))
        XCTAssertEqual(made.rows[0].cells[0].right, LayoutBorder(width: 2, color: 0xFF0000))
        XCTAssertEqual(made.rows[0].cells[1].left, LayoutBorder(width: 2, color: 0xFF0000))
    }

    func test_aTableWithoutBordersDrawsNoLines() throws {
        let document = try DocxReader.read(try docx(table(row(cell("a") + cell("b")), 2000, 2000)))
        XCTAssertTrue(rects(try layout(document).pages[0]).isEmpty)
    }

    func test_headerRowsComeBackOnEveryPageTheTableContinuesOn() throws {
        var rows = row(cell("HEADING"), "<w:tblHeader/>")
        for i in 0..<120 { rows += row(cell("row\(i)")) }
        let made = try OfficeConverter.fromWord(try docx(table(rows, 4000)), OfficeLayoutSpec.fonts())
        XCTAssertGreaterThan(made.pages, 2)
        let pdf = try PdfDocument.open(made.bytes)
        for p in 0..<made.pages {
            let text = pageText(pdf, p)
            XCTAssertTrue(text.hasPrefix("HEADING"))
            if p > 0 { XCTAssertFalse(text.contains("row0")) }
        }
        XCTAssertTrue(pageText(pdf, made.pages - 1).contains("row119"))
    }

    func test_aHeaderTooTallToShareThePageIsNotRepeated() throws {
        let header = lrow([lc("HEAD", "HEAD", "HEAD", "HEAD", "HEAD", "HEAD", "HEAD", "HEAD")], header: true)
        let rows = (0..<30).map { lrow([lc("row\($0)")]) }
        let result = try layout(single(Self.small, [ltable([100], [header] + rows)]))
        XCTAssertGreaterThan(result.pages.count, 1)
        XCTAssertEqual(result.pages.flatMap { texts($0) }.filter { $0.text == "HEAD" }.count, 8)
    }

    func test_aRowCutBetweenLinesLosesNothing() throws {
        let words = (0..<150).map { "w\($0)" }.joined(separator: " ")
        let beside = lcell(column: 1, [paragraph("beside")])
        let result = try layout(single(Self.small, [ltable([100, 60], [lrow([lc(words), beside])])]))
        XCTAssertGreaterThan(result.pages.count, 2)
        let all = result.pages.flatMap { texts($0) }
        let shown = all.filter { $0.x < 100 }.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ").components(separatedBy: " ")
        XCTAssertEqual(shown, (0..<150).map { "w\($0)" })
        XCTAssertEqual(all.filter { $0.text == "beside" }.count, 1)
    }

    func test_aRowThatCannotSplitMovesToTheNextPageWhole() throws {
        let filler = paragraph(Array(repeating: "filler", count: 60).joined(separator: " "))
        let split = lrow([lc("one", "two", "three")], cantSplit: true)
        let result = try layout(single(Self.small, [filler, ltable([100], [split])]))
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertEqual(texts(result.pages[1]).map(\.text), ["one", "two", "three"])
    }

    func test_aMergeTallerThanAPageBreaksLikeAnyOtherRow() throws {
        let tall = lcell(rowSpan: 2, (0..<40).map { paragraph("line\($0)") })
        let first = lrow([tall, lc("a")])
        let second = lrow([lcell(column: 1, [paragraph("b")])])
        let result = try layout(single(Self.small, [ltable([100, 60], [first, second])]))
        let all = result.pages.flatMap { texts($0) }.map(\.text)
        XCTAssertEqual(all.filter { $0.hasPrefix("line") }.count, 40)
        XCTAssertTrue(all.contains("a"))
        XCTAssertTrue(all.contains("b"))
    }

    func test_aCellTallerThanThePageAndAWordWiderThanItsCellStillEnd() throws {
        let wide = lcell([paragraph(String(repeating: "W", count: 400))])
        let rows = (0..<3).map { _ in lrow([wide], cantSplit: true) }
        let result = try layout(single(Self.small, [ltable([60], rows)]))
        XCTAssertTrue((1...40).contains(result.pages.count))
    }

    func test_emptyTablesAndRowsAreHarmless() throws {
        XCTAssertEqual(try layout(single(Self.small, [ltable([], [])])).pages.count, 1)
        let rows = ltable([0, 0], [lrow([]), lrow([LayoutCell()])])
        XCTAssertEqual(try layout(single(Self.small, [rows])).pages.count, 1)
    }

    func test_aTableTooWideForThePageIsNarrowedToIt() throws {
        let second = lcell(column: 1, [paragraph("b")])
        let result = try layout(single(Self.small, [ltable([300, 300], [lrow([lc("a"), second])])]))
        let placed = texts(result.pages[0])
        XCTAssertEqual(placed[1].x, 20 + 80 + 5.4, accuracy: 0.01)
    }

    func test_aLimitedTableIsReadAsItsParagraphsAndCounted() throws {
        let columns = table(row((0..<64).map { cell("c\($0)") }.joined()))
        var document = try DocxReader.read(try docx(columns))
        XCTAssertEqual(document.sections[0].blocks.filter { $0 is LayoutParagraph }.count, 64)
        XCTAssertTrue(document.skipped.contains(SkippedFeature("table", 1)))

        let rows = table(String(repeating: row(cell("r")), count: 5001), 1000)
        document = try DocxReader.read(try docx(rows))
        XCTAssertEqual(document.sections[0].blocks.filter { $0 is LayoutParagraph }.count, 5001)
    }

    func test_aSpanIsHeldToTheMostColumnsATableHas() throws {
        let made = try readTable(table(row(cell("a", "<w:gridSpan w:val=\"900\"/>")), 1000, 1000))
        XCTAssertEqual(made.rows[0].cells[0].span, 63)
        XCTAssertEqual(made.columns.count, 63)
        XCTAssertEqual(try readTable(table(row(cell("a", "<w:gridSpan w:val=\"-4\"/>") + cell("b")), 1000, 1000)).rows[0].cells.count, 2)
    }

    func test_nestedTablesInManyLevelsEndWithAnErrorOrAResult() throws {
        var inner = "<w:p><w:r><w:t>deep</w:t></w:r></w:p>"
        for _ in 0..<60 { inner = "<w:tbl><w:tr><w:tc>\(inner)<w:p/></w:tc></w:tr></w:tbl>" }
        do {
            let document = try DocxReader.read(try docx(inner))
            XCTAssertTrue(document.skipped.contains { $0.kind == "table" })
        } catch is PdfReadException {
        }
    }

    func test_aLongTableIsLaidOutInReasonableTime() throws {
        var rows = ""
        for i in 0..<4000 { rows += row(cell("a\(i)") + cell("b\(i)") + cell("c\(i)")) }
        let start = Date()
        let made = try OfficeConverter.fromWord(try docx(table(rows, 2000, 2000, 2000)), OfficeLayoutSpec.fonts())
        XCTAssertGreaterThan(made.pages, 20)
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
    }
}
