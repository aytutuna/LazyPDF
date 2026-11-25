import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/XlsxReaderTests.cs and reads the same golden files.

final class XlsxReaderTests: XCTestCase {
    func test_xlsxGoldenFile() throws {
        var output = ""
        for (name, package) in try XlsxSpec.read(try Golden.input("office-xlsx", "xlsx-input.txt")) {
            output += "> \(name)\n" + XlsxSpec.dump(try XlsxReader.read(package))
        }
        try Golden.check("office-xlsx", "xlsx-output.txt", output)
    }

    private static let oneSheet = "<sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets>"

    private func book(_ sheetData: String, strings: String? = nil, styles: String? = nil, workbook: String? = nil, extra: String? = nil) throws -> [UInt8] {
        var parts = [(key: "workbook", text: workbook ?? Self.oneSheet), (key: "sheet1", text: sheetData)]
        if let strings { parts.append(("strings", strings)) }
        if let styles { parts.append(("styles", styles)) }
        if let extra { parts.append(("sheet2", extra)) }
        return try XlsxSpec.package(parts)
    }

    private func problem(_ work: () throws -> Void) -> PdfReadProblem? {
        do {
            try work()
            return nil
        } catch let e as PdfReadException {
            return e.problem
        } catch {
            return nil
        }
    }

    private func columnName(_ column: Int) -> String {
        var letters = ""
        var c = column
        while c > 0 {
            letters = String(UnicodeScalar(UInt8(65 + (c - 1) % 26))) + letters
            c = (c - 1) / 26
        }
        return letters
    }

    private func cells(_ count: Int) -> String {
        "<sheetData><row r=\"1\">" + (1...count).map { "<c r=\"\(columnName($0))1\"><v>1</v></c>" }.joined() + "</row></sheetData>"
    }

    func test_moreCellsThanTheLimitAreRefused() throws {
        var limits = XlsxLimits()
        limits.maxCells = 3
        _ = try XlsxReader.read(try book(cells(3)), limits)
        let four = try book(cells(4))
        XCTAssertEqual(problem { _ = try XlsxReader.read(four, limits) }, .unsupported)
    }

    func test_blankCellsWithNothingToDrawAreNotCounted() throws {
        var limits = XlsxLimits()
        limits.maxCells = 1
        let sheet = "<sheetData><row r=\"1\"><c r=\"A1\"/><c r=\"B1\"/><c r=\"C1\"><v>1</v></c><c r=\"D1\"/></row></sheetData>"
        XCTAssertEqual(try XlsxReader.read(try book(sheet), limits).sheets[0].rows[0].cells.count, 1)
    }

    func test_moreSheetsThanTheLimitAreRefused() throws {
        let two = "<sheets><sheet name=\"A\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"B\" sheetId=\"2\" r:id=\"rId2\"/></sheets>"
        let package = try book("<sheetData/>", workbook: two, extra: "<sheetData/>")
        XCTAssertEqual(try XlsxReader.read(package).sheets.count, 2)
        var limits = XlsxLimits()
        limits.maxSheets = 1
        XCTAssertEqual(problem { _ = try XlsxReader.read(package, limits) }, .unsupported)
    }

    func test_moreMergedRangesThanTheLimitAreRefused() throws {
        let sheet = "<sheetData/><mergeCells><mergeCell ref=\"A1:B1\"/><mergeCell ref=\"A2:B2\"/></mergeCells>"
        let package = try book(sheet)
        var limits = XlsxLimits()
        limits.maxMergedRanges = 1
        XCTAssertEqual(problem { _ = try XlsxReader.read(package, limits) }, .unsupported)
        limits.maxMergedRanges = 2
        XCTAssertEqual(try XlsxReader.read(package, limits).sheets[0].merges.count, 2)
    }

    func test_moreSharedStringsThanTheLimitAreRefused() throws {
        let package = try book("<sheetData/>", strings: "<si><t>a</t></si><si><t>b</t></si>")
        var limits = XlsxLimits()
        limits.maxSharedStrings = 1
        XCTAssertEqual(problem { _ = try XlsxReader.read(package, limits) }, .unsupported)
    }

    func test_moreStylesAndFormatsThanTheLimitAreRefused() throws {
        let styles = try book("<sheetData/>", styles: "<cellXfs><xf/><xf/></cellXfs>")
        var limits = XlsxLimits()
        limits.maxStyles = 1
        XCTAssertEqual(problem { _ = try XlsxReader.read(styles, limits) }, .unsupported)
        let formats = try book("<sheetData/>", styles: "<numFmts><numFmt numFmtId=\"164\" formatCode=\"0\"/><numFmt numFmtId=\"165\" formatCode=\"0\"/></numFmts>")
        var formatLimits = XlsxLimits()
        formatLimits.maxNumberFormats = 1
        XCTAssertEqual(problem { _ = try XlsxReader.read(formats, formatLimits) }, .unsupported)
    }

    func test_longTextIsCutAndNotedWithoutSplittingAPair() throws {
        let sheet = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>abcdefgh</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>ab\u{1F600}cd</t></is></c><c r=\"C1\" t=\"str\"><v>abcdefgh</v></c></row></sheetData>"
        var limits = XlsxLimits()
        limits.maxTextLength = 3
        let workbook = try XlsxReader.read(try book(sheet), limits)
        XCTAssertEqual(workbook.sheets[0].rows[0].cells.map { $0.text }, ["abc", "ab", "abc"])
        XCTAssertEqual(workbook.skipped, [SkippedFeature("long-text", 3)])
    }

    func test_tooMuchTextInAllIsRefused() throws {
        let sheet = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>abcd</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>abcd</t></is></c></row></sheetData>"
        let package = try book(sheet)
        var limits = XlsxLimits()
        limits.maxTotalText = 7
        XCTAssertEqual(problem { _ = try XlsxReader.read(package, limits) }, .unsupported)
        limits.maxTotalText = 8
        _ = try XlsxReader.read(package, limits)
    }

    func test_textRewrittenByAFormatCountsTowardTheTotal() throws {
        let cells = String(repeating: "<c t=\"s\" s=\"1\"><v>0</v></c>", count: 3)
        func styles(_ code: String) -> String {
            "<numFmts><numFmt numFmtId=\"164\" formatCode=\"\(code)\"/></numFmts><cellXfs><xf/><xf numFmtId=\"164\"/></cellXfs>"
        }
        var limits = XlsxLimits()
        limits.maxTotalText = 20
        let sheet = "<sheetData><row r=\"1\">\(cells)</row></sheetData>"
        let plain = try book(sheet, strings: "<si><t>abcdefgh</t></si>", styles: styles("@"))
        XCTAssertEqual(try XlsxReader.read(plain, limits).sheets[0].rows[0].cells[2].text, "abcdefgh")
        let padded = try book(sheet, strings: "<si><t>abcdefgh</t></si>", styles: styles("@ @"))
        XCTAssertEqual(problem { _ = try XlsxReader.read(padded, limits) }, .unsupported)
    }

    func test_aRowOutsideTheSheetIsDamage() throws {
        let past = try book("<sheetData><row r=\"1048577\"/></sheetData>")
        let zero = try book("<sheetData><row r=\"0\"/></sheetData>")
        XCTAssertEqual(problem { _ = try XlsxReader.read(past) }, .damaged)
        XCTAssertEqual(problem { _ = try XlsxReader.read(zero) }, .damaged)
        _ = try XlsxReader.read(try book("<sheetData><row r=\"1048576\"><c r=\"XFD1048576\"><v>1</v></c></row></sheetData>"))
    }

    func test_aNumberFormatLongerThanTheLimitFallsBackToGeneral() throws {
        let code = String(repeating: "0", count: 300)
        let package = try book("<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"><v>5</v></c></row></sheetData>",
                               styles: "<numFmts><numFmt numFmtId=\"164\" formatCode=\"\(code)\"/></numFmts><cellXfs><xf/><xf numFmtId=\"164\"/></cellXfs>")
        XCTAssertEqual(try XlsxReader.read(package).sheets[0].rows[0].cells[0].text, "5")
    }

    func test_filesThatAreNotXlsxAreTurnedAway() throws {
        let ole: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0]
        XCTAssertEqual(problem { _ = try XlsxReader.read(ole) }, .unsupported)
        let word = try DocxSpec.package([(key: "document", text: "<w:p/>")])
        XCTAssertEqual(problem { _ = try XlsxReader.read(word) }, .unsupported)
        XCTAssertThrowsError(try XlsxReader.read([1, 2, 3, 4, 5]))
    }

    func test_aWorksheetWithTheWrongRootIsDamage() throws {
        let package = try XlsxSpec.package([
            (key: "workbook", text: Self.oneSheet),
            (key: "part xl/worksheets/sheet1.xml", text: "<other xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>"),
            (key: "relationships", text: "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"),
        ])
        XCTAssertEqual(problem { _ = try XlsxReader.read(package) }, .damaged)
    }

    func test_columnLookupsFollowTheRuns() throws {
        let sheet = try XlsxReader.read(try book("<cols><col min=\"2\" max=\"3\" width=\"20\" hidden=\"1\"/></cols><sheetData/>")).sheets[0]
        XCTAssertEqual(sheet.width(of: 1), sheet.defaultColumnWidth)
        XCTAssertNotEqual(sheet.width(of: 3), sheet.defaultColumnWidth)
        XCTAssertTrue(sheet.isColumnHidden(2))
        XCTAssertFalse(sheet.isColumnHidden(4))
    }
}
