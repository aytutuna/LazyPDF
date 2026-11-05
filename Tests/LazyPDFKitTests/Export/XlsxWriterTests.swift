import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/XlsxWriterTests.cs: the same cases, and one more for `roundTrip`, which stands in for
// double.ToString("R").

final class XlsxWriterTests: XCTestCase {
    private let s = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private let rel = "http://schemas.openxmlformats.org/package/2006/relationships"

    private func cells(_ package: [UInt8], _ name: String) throws -> [XmlElement] {
        ExportKit.descendants(try ExportKit.part(package, name), s, "c")
    }

    private func reference(_ cell: XmlElement) -> String { cell.attribute(XmlName("", "r"))?.value ?? "" }

    private func type(_ cell: XmlElement) -> String? { cell.attribute(XmlName("", "t"))?.value }

    func test_eachTableIsASheetAndNumbersAreNumbers() throws {
        let package = try XlsxWriter.make(ExportLayout.analyze(ExportKit.report()))
        let sheets = ExportKit.descendants(try ExportKit.part(package, "xl/workbook.xml"), s, "sheet").compactMap { $0.attribute(XmlName("", "name"))?.value }
        XCTAssertEqual(sheets, ["Table 1 (p1)", "Table 1 (p2)", "Table 1 (p3)"])

        let cells = Dictionary(uniqueKeysWithValues: try self.cells(package, "xl/worksheets/sheet1.xml").map { (reference($0), $0) })
        let a1 = try XCTUnwrap(cells["A1"])
        let text = ExportKit.descendants(a1, s, "t")
        XCTAssertEqual(text.count, 1)
        XCTAssertEqual(text[0].value, "Item")
        XCTAssertEqual(type(a1), "inlineStr")
        let b2 = try XCTUnwrap(cells["B2"])
        XCTAssertEqual(b2.element(XmlName(s, "v"))?.value, "1250.5")
        XCTAssertNil(type(b2))
    }

    func test_thePackageIsConsistent() throws {
        let package = try XlsxWriter.make(ExportLayout.analyze(ExportKit.report()))
        let entries = try ExportKit.entries(package)
        for item in ExportKit.descendants(try ExportKit.part(package, "xl/_rels/workbook.xml.rels"), rel, "Relationship") {
            XCTAssertTrue(entries.contains("xl/" + (item.attribute(XmlName("", "Target"))?.value ?? "")))
        }
        let types = try ExportKit.unzip(package, "[Content_Types].xml")
        for i in 1...3 { XCTAssertTrue(types.contains("/xl/worksheets/sheet\(i).xml")) }
        for e in entries where e.hasSuffix(".xml") || e.hasSuffix(".rels") { _ = try ExportKit.part(package, e) }
    }

    func test_withoutTablesEachPageIsASheetOfRowsAndColumns() throws {
        let content = "BT /F1 11 Tf 72 700 Td (Name) Tj ET BT /F1 11 Tf 300 700 Td (Total) Tj ET\n"
            + "BT /F1 11 Tf 72 684 Td (Rent) Tj ET BT /F1 11 Tf 300 684 Td (950) Tj ET"
        let package = try XlsxWriter.make(ExportLayout.analyze(ExportKit.open(content)))
        let sheets = ExportKit.descendants(try ExportKit.part(package, "xl/workbook.xml"), s, "sheet")
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].attribute(XmlName("", "name"))?.value, "Page 1")
        let cells = Dictionary(uniqueKeysWithValues: try self.cells(package, "xl/worksheets/sheet1.xml").map { (reference($0), $0) })
        XCTAssertEqual(cells.keys.sorted(), ["A1", "A2", "B1", "B2"])
        XCTAssertEqual(cells["B2"]?.element(XmlName(s, "v"))?.value, "950")
        XCTAssertEqual(cells["A2"]?.value, "Rent")
    }

    func test_anEmptyDocumentHasOneEmptySheet() throws {
        let package = try XlsxWriter.make(ExportDocument(nil, [], 11))
        let sheets = ExportKit.descendants(try ExportKit.part(package, "xl/workbook.xml"), s, "sheet")
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].attribute(XmlName("", "name"))?.value, "Sheet1")
        XCTAssertTrue(try cells(package, "xl/worksheets/sheet1.xml").isEmpty)
    }

    func test_turkishTextAndLineBreaksInCellsSurvive() throws {
        let table = ExportTable(DisplayRect(0, 0, 10, 10), [["Şehir", "İlçe"], ["Ağrı", "Doğubayazıt\nMerkez"]], nil, false)
        let document = ExportDocument(nil, [ExportPage(0, 612, 792, [table], [], [])], 11)
        let values = try cells(XlsxWriter.make(document), "xl/worksheets/sheet1.xml").map { $0.value }
        XCTAssertEqual(values, ["Şehir", "İlçe", "Ağrı", "Doğubayazıt\nMerkez"])
    }

    func test_textThatLooksLikeACodeStaysText() throws {
        let table = ExportTable(DisplayRect(0, 0, 10, 10), [["007", "=SUM(A1)"], ["12", "1e5"]], nil, false)
        let document = ExportDocument(nil, [ExportPage(0, 612, 792, [table], [], [])], 11)
        let cells = Dictionary(uniqueKeysWithValues: try self.cells(XlsxWriter.make(document), "xl/worksheets/sheet1.xml").map { (reference($0), $0) })
        XCTAssertEqual(cells["A1"].flatMap(type), "inlineStr")
        XCTAssertEqual(cells["B1"].flatMap(type), "inlineStr")
        XCTAssertNil(cells["A2"].flatMap(type))
        XCTAssertEqual(cells["B2"].flatMap(type), "inlineStr")
    }

    func test_numbersAreRecognised() {
        let cases: [(String, Double)] = [
            ("42", 42), ("-7", -7), ("0", 0), ("0.5", 0.5), ("3.14", 3.14), ("12,5", 12.5), ("1,23", 1.23), ("1,234", 1234),
            ("1,234.56", 1234.56), ("1.234,56", 1234.56), ("1.234.567", 1234567), ("1,234,567", 1234567), ("-1.234,5", -1234.5), (" 8 ", 8),
        ]
        for (text, expected) in cases {
            guard let value = XlsxWriter.tryNumber(text) else {
                XCTFail("\"\(text)\" is a number")
                continue
            }
            XCTAssertEqual(value, expected, accuracy: 1e-9, text)
        }
    }

    func test_otherTextIsNotANumber() {
        for text in ["", "abc", "007", "1.2.3", "12,34,56", "1e5", "12%", "$5", "-", "1,", "12345678901234567", "1.234,56,7"] {
            XCTAssertNil(XlsxWriter.tryNumber(text), "\"\(text)\" is not a number")
        }
    }

    func test_numbersAreWrittenAsDotNetWritesThem() {
        let cases: [(Double, String)] = [
            (1250.5, "1250.5"), (950, "950"), (0.5, "0.5"), (0.0001, "0.0001"), (0.00001, "1E-05"), (1.5e-7, "1.5E-07"),
            (123456789012345, "123456789012345"), (1e15, "1E+15"), (1.5e20, "1.5E+20"), (-3.25, "-3.25"), (0, "0"), (100, "100"),
            (0.1 + 0.2, "0.30000000000000004"), (1234.56, "1234.56"),
        ]
        for (value, text) in cases { XCTAssertEqual(XlsxWriter.roundTrip(value), text, "\(value)") }
    }
}
