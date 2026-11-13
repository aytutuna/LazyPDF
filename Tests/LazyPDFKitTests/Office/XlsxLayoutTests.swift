import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/XlsxLayoutTests.cs and reads the same golden files.

final class XlsxLayoutTests: XCTestCase {
    private static var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 14, minute: 5))!
    }

    private func num(_ value: Double) -> String {
        String(format: "%.2f", (value * 100).rounded(.toNearestOrAwayFromZero) / 100 + 0.0)
    }

    private func styleName(_ style: FontStyles) -> String {
        switch (style.contains(.bold), style.contains(.italic)) {
        case (true, true): return "Bold, Italic"
        case (true, false): return "Bold"
        case (false, true): return "Italic"
        default: return "Regular"
        }
    }

    private func layout(_ package: [UInt8], _ limits: XlsxLimits = .standard) throws -> LayoutResult {
        try XlsxLayout.run(try XlsxReader.read(package, limits), LayoutFonts(OfficeLayoutSpec.fonts()), Self.now, "Book1.xlsx")
    }

    private func dump(_ layout: LayoutResult) -> String {
        var output = ""
        for (i, page) in layout.pages.enumerated() {
            output += "page \(i + 1) \(num(page.width)) \(num(page.height))\n"
            for box in page.boxes {
                switch box {
                case .text(let t):
                    output += "text \(num(t.x)) \(num(t.baseline)) \(t.family)/\(styleName(t.style)) \(num(t.size)) \(String(format: "%06x", t.color)) +\(num(t.spaceExtra))\(t.rightToLeft ? " rtl" : "") \"\(OfficeLayoutSpec.escape(t.text))\"\n"
                case .rect(let r):
                    output += "rect \(num(r.x)) \(num(r.y)) \(num(r.width)) \(num(r.height)) \(String(format: "%06x", r.color))\n"
                case .image, .path:
                    break
                }
            }
        }
        for s in layout.skipped { output += "skipped \(s.kind) \(s.count)\n" }
        return output
    }

    func test_layoutGoldenFile() throws {
        var output = ""
        for (name, package) in try XlsxSpec.read(try Golden.input("office-xlsx", "xlsx-layout-input.txt")) {
            output += "> \(name)\n" + dump(try layout(package))
        }
        try Golden.check("office-xlsx", "xlsx-layout-output.txt", output)
    }

    func test_rightToLeftSheetGoldenFile() throws {
        var output = ""
        for (name, package) in try XlsxSpec.read(try Golden.input("office-xlsx", "rtl-input.txt")) {
            let made = try XlsxLayout.run(try XlsxReader.read(package), LayoutFonts(OfficeLayoutSpec.scriptFonts()), Self.now, "Book1.xlsx")
            output += "> \(name)\n" + dump(made)
        }
        try Golden.check("office-xlsx", "rtl-output.txt", output)
    }

    private static let oneSheet = "<sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets>"

    private func book(_ sheet: String, workbook: String? = nil) throws -> [UInt8] {
        try XlsxSpec.package([(key: "workbook", text: workbook ?? Self.oneSheet), (key: "sheet1", text: sheet)])
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

    func test_aBookWithNothingInItHasNothingToPrint() throws {
        let package = try book("<sheetData><row r=\"1\"/></sheetData>")
        XCTAssertEqual(problem { _ = try layout(package) }, .unsupported)
    }

    func test_marginsThatLeaveNoRoomAreRefused() throws {
        let package = try book("<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData><pageMargins left=\"5\" right=\"5\" top=\"1\" bottom=\"1\" header=\"0\" footer=\"0\"/>")
        XCTAssertEqual(problem { _ = try layout(package) }, .unsupported)
    }

    func test_aBigPrintAreaStopsAtThePageLimit() throws {
        let names = "<sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets><definedNames><definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">S!$A$1:$XFC$1048575</definedName></definedNames>"
        let package = try book("<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>", workbook: names)
        XCTAssertEqual(problem { _ = try layout(package) }, .unsupported)
    }

    func test_thousandsOfTinyRowsOnOnePageStopAtTheBoxLimit() throws {
        var sheet = "<sheetData>"
        for r in 1...600_000 { sheet += "<row r=\"\(r)\" ht=\"0.0005\" customHeight=\"1\"><c r=\"A\(r)\" s=\"1\"><v>1</v></c></row>" }
        sheet += "</sheetData>"
        let styles = "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
            + "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFFFFF00\"/></patternFill></fill></fills>"
            + "<borders count=\"2\"><border><left/><right/><top/><bottom/></border><border><left style=\"double\"><color rgb=\"FF000000\"/></left><right style=\"double\"><color rgb=\"FF000000\"/></right><top/><bottom style=\"double\"><color rgb=\"FF000000\"/></bottom></border></borders>"
            + "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/><xf numFmtId=\"0\" fontId=\"0\" fillId=\"2\" borderId=\"1\"/></cellXfs>"
        let package = try XlsxSpec.package([(key: "workbook", text: Self.oneSheet), (key: "sheet1", text: sheet), (key: "styles", text: styles)])
        XCTAssertEqual(problem { _ = try layout(package) }, .unsupported)
    }

    func test_aCellFarDownTheSheetPrintsOnItsOwnPageWithoutTheBlankOnes() throws {
        let result = try layout(try book("<sheetData><row r=\"900000\"><c r=\"A900000\"><v>7</v></c></row></sheetData>"))
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertTrue(result.pages[0].boxes.contains { if case .text(let t) = $0 { return t.text == "7" } else { return false } })
    }

    func test_fitToPageNeverUsesMorePagesThanAsked() throws {
        var rows = ""
        for r in 1...300 {
            rows += "<row r=\"\(r)\">"
            for c in 0..<30 { rows += "<c r=\"\(String(UnicodeScalar(UInt8(65 + c % 26))))\(c >= 26 ? "A" : "")\(r)\"><v>\(r)</v></c>" }
            rows += "</row>"
        }
        let sheet = "<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr><sheetData>\(rows)</sheetData><pageSetup fitToWidth=\"2\" fitToHeight=\"3\"/>"
        XCTAssertLessThanOrEqual(try layout(try book(sheet)).pages.count, 6)
    }

    func test_theConverterWritesAPdfWithTheCellText() throws {
        let package = try XlsxSpec.package([
            (key: "workbook", text: Self.oneSheet),
            (key: "strings", text: "<si><t>Hello sheet</t></si>"),
            (key: "sheet1", text: "<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row></sheetData>"),
        ])
        let made = try OfficeConverter.fromExcel(package, OfficeLayoutSpec.fonts(), fileName: "Book1.xlsx")
        XCTAssertEqual(made.pages, 1)
        let pdf = try PdfDocument.open(made.bytes)
        XCTAssertTrue(TextPage.create(pdf, pdf.pages[0]).text.contains("Hello sheet"))
    }
}
