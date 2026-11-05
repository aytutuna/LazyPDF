import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/ObjectTableTests.cs: the same cases.

final class ObjectTableTests: XCTestCase {
    func test_objectsLoadOnceAndAreTheSameInstance() throws {
        let document = try PdfDocument.open(TestPdf.simple())
        assertSame(document.get(2), document.get(2))
        assertSame(document.get(2), document.resolve(PdfReference(2, 0)))
        XCTAssertNil(document.get(0))
        XCTAssertNil(document.get(-5))
        XCTAssertNil(document.get(900))
    }

    func test_resolveFollowsChainsAndStopsAtLoops() throws {
        let pdf = TestPdf.withPages(1)
            .obj(10, "11 0 R").obj(11, "12 0 R").obj(12, "(end)")
            .obj(20, "21 0 R").obj(21, "20 0 R")
            .obj(22, "22 0 R")
            .obj(23, "null")
        let document = try PdfDocument.open(pdf.finish())
        XCTAssertTrue(document.resolve(PdfReference(10, 0)) is PdfString)
        XCTAssertNil(document.resolve(PdfReference(20, 0)))
        XCTAssertNil(document.resolve(PdfReference(22, 0)))
        XCTAssertNil(document.resolve(PdfReference(23, 0)))
        XCTAssertNil(document.resolve(nil))
        let number = PdfNumber(3)
        assertSame(number, document.resolve(number))
    }

    func test_typedHelpersResolveAndFilter() throws {
        let pdf = TestPdf.withPages(1)
            .obj(10, "<</A 11 0 R /B 12 0 R /C 13 0 R /D 14 0 R /E 15 0 R /F 16 0 R /G (text) /H 17 0 R /I 18 0 R>>")
            .obj(11, "<</K 1>>").obj(12, "[1 2]").obj(13, "/Name").obj(14, "2.5").obj(15, "true").obj(16, "90.0")
            .obj(17, "[0 0 10 20]").obj(18, "[10 20 0 0]")
        let document = try PdfDocument.open(pdf.finish())
        XCTAssertNil(document.dict(nil, "x"))
        let dict = try XCTUnwrap(document.get(10) as? PdfDictionary)
        XCTAssertNotNil(document.dict(dict, "A"))
        XCTAssertNil(document.dict(dict, "B"))
        XCTAssertEqual(document.array(dict, "B")?.items.count, 2)
        XCTAssertEqual(document.name(dict, "C"), "Name")
        XCTAssertNil(document.name(dict, "G"))
        XCTAssertEqual(document.number(dict, "D"), 2.5)
        XCTAssertNil(document.integer(dict, "D"))
        XCTAssertEqual(document.integer(dict, "F"), 90)
        XCTAssertEqual(document.bool(dict, "E"), true)
        XCTAssertNil(document.number(dict, "missing"))
        XCTAssertNil(document.stream(dict, "A"))
        XCTAssertEqual(document.rect(dict, "H"), PdfRect(0, 0, 10, 20))
        XCTAssertEqual(document.rect(dict, "I"), PdfRect(0, 0, 10, 20))
        XCTAssertNil(document.rect(dict, "B"))
    }

    func test_objectThatCannotBeParsedReadsAsNullOnce() throws {
        let pdf = TestPdf.withPages(1).obj(10, "<</Broken (never closed")
        let document = try PdfDocument.open(pdf.finish())
        XCTAssertTrue(document.get(10) is PdfNull)
        XCTAssertNil(document.resolve(PdfReference(10, 0)))
        XCTAssertEqual(document.repairs.filter { $0.contains("Object 10 could not be read") }.count, 1)
    }

    func test_objectNumbersListWhatIsInUse() throws {
        let document = try PdfDocument.open(TestPdf.withPages(1).obj(9, "1").finish())
        XCTAssertEqual(document.objectNumbers, [1, 2, 3, 4, 9])
    }

    func test_tableThatStartsAtOneWithTheFreeHeadIsShifted() throws {
        let text = TestPdf.text(TestPdf.simple(1))
        let fixedUp = text.replacingOccurrences(of: "xref\n0 5\n", with: "xref\n1 5\n")
        let document = try PdfDocument.open(TestPdf.latin(fixedUp))
        XCTAssertTrue(document.repairs.isEmpty)
        XCTAssertEqual(document.pages.count, 1)
    }

    func test_tableEntriesMarkedInUseAtOffsetZeroAreFree() throws {
        let file = TestPdf.simple(1)
        let xref = try XCTUnwrap(file.lastIndexOf(TestPdf.latin("xref\n0")))
        var lines = TestPdf.text(Array(file[xref...])).components(separatedBy: "\n")
        lines[2] = "0000000000 00000 n "
        let broken = Array(file[0..<xref]) + TestPdf.latin(lines.joined(separator: "\n"))
        XCTAssertEqual(try PdfDocument.open(broken).pages.count, 1)
    }

    func test_pathOverloadReadsAFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("read.pdf")
        try Data(TestPdf.simple(2)).write(to: path)
        let document = try PdfDocument.open(path: path.path)
        XCTAssertEqual(document.pages.count, 2)
    }

    func test_objectListedAsFreeReadsAsNull() throws {
        // The table calls object 4 free, so it is, whatever the file holds at its old place.
        let file = TestPdf.simple(1)
        let xref = try XCTUnwrap(file.lastIndexOf(TestPdf.latin("xref\n0")))
        var lines = TestPdf.text(Array(file[xref...])).components(separatedBy: "\n")
        lines[6] = "0000000000 00000 f "
        let document = try PdfDocument.open(Array(file[0..<xref]) + TestPdf.latin(lines.joined(separator: "\n")))
        XCTAssertNil(document.get(4))
    }
}
