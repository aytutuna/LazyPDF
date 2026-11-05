import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/RepairTests.cs: the same cases. The time bounds are the C#'s; the
// runners build the tests in debug mode, which is why the C# numbers have room.

final class RepairTests: XCTestCase {
    @discardableResult
    private func openWithPages(_ file: [UInt8], _ pages: Int, _ repair: String?, file path: StaticString = #filePath, line: UInt = #line) throws -> PdfDocument {
        let document = try PdfDocument.open(file)
        XCTAssertEqual(document.pages.count, pages, file: path, line: line)
        if let repair {
            XCTAssertTrue(document.repairs.contains { $0.range(of: repair, options: .caseInsensitive) != nil },
                          "repairs: \(document.repairs)", file: path, line: line)
        } else {
            XCTAssertTrue(document.repairs.isEmpty, "repairs: \(document.repairs)", file: path, line: line)
        }
        return document
    }

    func test_aGoodFileNeedsNoRepair() throws {
        try openWithPages(TestPdf.simple(3), 3, nil)
    }

    func test_bytesBeforeTheHeaderAreCutOff() throws {
        let file = TestPdf.latin("junk before\r\n") + TestPdf.simple(2)
        let document = try openWithPages(file, 2, "before the %PDF header")
        XCTAssertEqual(document.length, file.count - 13)
    }

    func test_headerTooFarInIsNotAPdf() {
        let file = [UInt8](repeating: 0, count: 2000) + TestPdf.simple()
        assertReadFails(try PdfDocument.open(file), .notPdf)
    }

    func test_missingStartxrefRebuildsTheTable() throws {
        try openWithPages(TestPdf.replace(TestPdf.simple(), "startxref", "startxxxxx"), 2, "startxref")
    }

    func test_startxrefPastTheEndRebuildsTheTable() throws {
        let document = try openWithPages(
            TestPdf().obj(1, "<</Type /Catalog /Pages 2 0 R>>").obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
                .obj(3, "<</Type /Page /Parent 2 0 R>>").finish(startxref: "99999999"), 1, "startxref")
        XCTAssertTrue(document.xrefRebuilt)
    }

    func test_startxrefPointingAtGarbageRebuildsTheTable() throws {
        let file = TestPdf.simple()
        let at = try XCTUnwrap(file.lastIndexOf(TestPdf.latin("startxref")))
        let start = TestPdf.text(Array(file[(at + 10)...])).components(separatedBy: "\n")[0]
        try openWithPages(TestPdf.replace(file, "startxref\n" + start, "startxref\n20"), 2, "rebuilt")
    }

    func test_offsetsSlightlyOffAreFoundByTheirHeaders() throws {
        let document = try openWithPages(TestPdf.withPages(2).finish(shift: 7), 2, "found at byte")
        XCTAssertFalse(document.xrefRebuilt)
    }

    func test_offsetsNamingAnotherObjectAreFoundByTheirHeaders() throws {
        let file = TestPdf.simple(2)
        // Object 3 listed at the offset of object 4.
        let xref = try XCTUnwrap(file.lastIndexOf(TestPdf.latin("xref\n0")))
        var lines = TestPdf.text(Array(file[xref...])).components(separatedBy: "\n")
        lines[5] = lines[6]
        let broken = Array(file[0..<xref]) + TestPdf.latin(lines.joined(separator: "\n"))
        let document = try PdfDocument.open(broken)
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertTrue(document.repairs.contains { $0.contains("Object 3") })
    }

    func test_brokenPrevRebuildsTheTableAndTheNewestObjectWins() throws {
        let pdf = TestPdf.withPages(1)
        let first = pdf.finish()
        let update = first.count
        let objectText = "3 0 obj\n<</Type /Page /Parent 2 0 R /Rotate 90 /Contents 4 0 R>>\nendobj\n"
        let text = objectText + "xref\n3 1\n" + String(format: "%010ld", update) + " 00000 n \n"
            + "trailer\n<</Size 5 /Root 1 0 R /Prev 5000000>>\nstartxref\n\(update + objectText.count)\n%%EOF\n"
        let document = try openWithPages(first + TestPdf.latin(text), 1, "rebuilt")
        XCTAssertEqual(document.pages[0].rotate, 90)
    }

    func test_prevLoopRebuildsTheTable() throws {
        let file = TestPdf.simple(1)
        let xref = try XCTUnwrap(file.lastIndexOf(TestPdf.latin("xref\n0")))
        let looped = TestPdf.text(file).replacingOccurrences(of: "/Root 1 0 R>>", with: "/Root 1 0 R /Prev \(xref)>>")
        try openWithPages(TestPdf.latin(looped), 1, "point back")
    }

    func test_wrongLengthIsFoundByEndstream() throws {
        let pdf = TestPdf.withPages(1).stream(9, "", "twelve bytes", length: 3).stream(10, "", "ten bytes!", length: 500)
            .stream(11, "", "no length", length: -1)
        let document = try openWithPages(pdf.finish(), 1, nil)
        XCTAssertEqual(TestPdf.text(document.rawData(try XCTUnwrap(document.get(9) as? PdfStream))), "twelve bytes")
        XCTAssertEqual(TestPdf.text(document.rawData(try XCTUnwrap(document.get(10) as? PdfStream))), "ten bytes!")
        XCTAssertEqual(TestPdf.text(document.rawData(try XCTUnwrap(document.get(11) as? PdfStream))), "no length")
        XCTAssertEqual(document.repairs.filter { $0.contains("/Length") }.count, 3)
    }

    func test_streamWithoutEndstreamEndsAtEndobj() throws {
        let pdf = TestPdf.withPages(1).stream(9, "", "cut short", length: 400, endstream: false)
        let document = try openWithPages(pdf.finish(), 1, nil)
        XCTAssertEqual(TestPdf.text(document.rawData(try XCTUnwrap(document.get(9) as? PdfStream))), "cut short")
        XCTAssertTrue(document.repairs.contains { $0.contains("/Length") })
    }

    func test_missingEndobjIsNoProblem() throws {
        let file = TestPdf.latin(TestPdf.text(TestPdf.simple(2)).replacingOccurrences(of: "endobj\n", with: ""))
        // The offsets moved, so the table is wrong as well: both are got round.
        XCTAssertEqual(try PdfDocument.open(file).pages.count, 2)
        let rebuilt = TestPdf.replace(file, "startxref", "startxxxxx")
        XCTAssertEqual(try PdfDocument.open(rebuilt).pages.count, 2)
    }

    func test_missingTrailerRebuildsAndFindsTheCatalog() throws {
        let file = TestPdf.withPages(2).finishWithoutXref()
        let document = try openWithPages(file, 2, "no trailer")
        XCTAssertEqual(document.name(document.catalog, "Type"), "Catalog")
    }

    func test_trailerWithoutRootFindsTheCatalogByType() throws {
        let document = try openWithPages(TestPdf.withPages(2).finish(""), 2, "catalog")
        XCTAssertNotNil(document.trailer["Root"])
    }

    func test_truncatedFileKeepsWhatIsThere() throws {
        let file = TestPdf.simple(3)
        let cut = Array(file[0..<(file.count - 120)])
        let document = try PdfDocument.open(cut)
        XCTAssertTrue(document.xrefRebuilt)
        XCTAssertEqual(document.pages.count, 3)
    }

    func test_noCatalogMakesOneFromThePageTree() throws {
        let pdf = TestPdf().obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>").obj(3, "<</Type /Page /Parent 2 0 R>>")
            .obj(4, "<</Type /Page /Parent 2 0 R>>")
        try openWithPages(pdf.finishWithoutXref(), 2, "made one")
    }

    func test_noTreeEitherMakesOneFromThePages() throws {
        let pdf = TestPdf().obj(3, "<</Type /Page /MediaBox [0 0 10 10]>>").obj(4, "<</Type /Page /MediaBox [0 0 20 20]>>")
        let document = try openWithPages(pdf.finishWithoutXref(), 2, "made a page tree")
        XCTAssertEqual(document.pages[1].mediaBox.width, 20)
    }

    func test_laterDefinitionOfAnObjectWinsInTheScan() throws {
        let pdf = TestPdf.withPages(1).obj(3, "<</Type /Page /Parent 2 0 R /Rotate 180 /Contents 4 0 R>>")
        let document = try openWithPages(pdf.finishWithoutXref(), 1, "scanning")
        XCTAssertEqual(document.pages[0].rotate, 180)
    }

    func test_pdfInsideAStreamIsNotMistakenForObjects() throws {
        let inner = "9 0 obj\n<</Type /Page /Rotate 90>>\nendobj\n"
        let pdf = TestPdf.withPages(1).stream(8, "", "%PDF-1.4\n" + inner + "trailer\n<</Root 9 0 R>>\n")
        let document = try openWithPages(pdf.finishWithoutXref(), 1, "scanning")
        XCTAssertEqual(document.pages[0].rotate, 0)
    }

    func test_noPagesAnywhereIsDamaged() {
        let file = TestPdf.latin("%PDF-1.4\n1 0 obj\n<</Foo 1>>\nendobj\n")
        assertReadFails(try PdfDocument.open(file), .damaged)
    }

    func test_unclosedStringsDoNotMakeTheScanQuadratic() throws {
        let pdf = TestPdf.withPages(1)
        for i in 0..<3000 { pdf.write("\(100 + i) 0 obj\n(never closed\n") }
        let started = Date()
        let document = try PdfDocument.open(pdf.finishWithoutXref())
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func test_manyBrokenStreamsStayLinear() throws {
        let pdf = TestPdf.withPages(1)
        let data = String(repeating: "x", count: 200)
        for i in 0..<5000 { pdf.stream(100 + i, "", data, length: 7) }
        let started = Date()
        let document = try PdfDocument.open(pdf.finish())
        for i in 0..<5000 { XCTAssertEqual(document.rawData(try XCTUnwrap(document.get(100 + i) as? PdfStream)).count, 200) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func test_repairListIsCapped() throws {
        let pdf = TestPdf.withPages(1)
        for i in 0..<300 { pdf.stream(100 + i, "", "abc", length: 99) }
        let document = try PdfDocument.open(pdf.finish())
        for i in 0..<300 { _ = document.rawData(try XCTUnwrap(document.get(100 + i) as? PdfStream)) }
        XCTAssertEqual(document.repairs.count, 101)
    }

    func test_notPdfAndEmptyFilesAreRefused() {
        for file in [[UInt8](), TestPdf.latin("hello"), TestPdf.latin("%PDF")] {
            assertReadFails(try PdfDocument.open(file), .notPdf)
        }
    }

    func test_mutatedFilesOpenOrFailCleanly() throws {
        let basis = TestPdf.simple(4)
        var random = DotNetRandom(376)
        for round in 0..<400 {
            var file = basis
            let edits = 1 + round % 6
            for _ in 0..<edits {
                let at = random.next(file.count)
                file[at] = UInt8(random.next(256))
            }
            if round % 5 == 0 { file = Array(file[0..<random.next(file.count)]) }
            do {
                let document = try PdfDocument.open(file)
                for page in document.pages { _ = page.contents() }
            } catch is PdfReadException {
            }
        }
    }
}
