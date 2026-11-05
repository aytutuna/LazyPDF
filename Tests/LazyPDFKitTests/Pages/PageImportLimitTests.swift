import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageImportLimitTests.cs: the same cases. Files built to be awkward: loops, a very
// long chain, references to nothing, data that does not decode.

final class PageImportLimitTests: XCTestCase {
    private func awkward(_ pageResources: String = "/Font <</F1 10 0 R>>", _ add: (TestPdf) -> Void) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 100]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <<\(pageResources)>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>")
        pdf.stream(5, "", "BT /F1 12 Tf (Page 1) Tj ET /X Do /F2 gs /G gs")
        pdf.stream(6, "", "BT (Page 2) Tj ET")
        pdf.obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        add(pdf)
        return pdf.finish()
    }

    func test_objectsThatPointAtEachOtherAreCopiedOnce() throws {
        let file = awkward { pdf in
            pdf.obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FontDescriptor 11 0 R /Self 10 0 R>>")
            pdf.obj(11, "<</Type /FontDescriptor /Font 10 0 R /Loop [11 0 R 10 0 R]>>")
        }
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(file), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let font = try XCTUnwrap(again.dict(again.dict(again.pages[1].resources, "Font"), "F1"))
        assertSame(font, again.resolve(font["Self"]))
        assertSame(font, again.dict(try XCTUnwrap(again.resolve(font["FontDescriptor"]) as? PdfDictionary), "Font"))
    }

    func test_aLongChainOfObjectsNeedsNoStack() throws {
        let length = 60_000
        let file = awkward { pdf in
            pdf.obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Chain 100 0 R>>")
            for i in 0..<length { pdf.obj(100 + i, i + 1 < length ? "<</Next \(101 + i) 0 R>>" : "<</End true>>") }
        }
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(file), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        var links = 0
        var node = again.resolve(again.dict(again.dict(again.pages[1].resources, "Font"), "F1")?["Chain"]) as? PdfDictionary
        while let current = node, links <= length {
            links += 1
            node = again.dict(current, "Next")
        }
        XCTAssertEqual(links, length)
    }

    func test_referencesToNothingAreLeftOut() throws {
        let file = awkward("/Font <</F1 10 0 R /F2 77 0 R>> /ExtGState <</G 78 0 R>>") { _ in }
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(file), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        XCTAssertEqual(again.repairs, [])
        XCTAssertFalse(try XCTUnwrap(again.dict(again.pages[1].resources, "Font")).containsKey("F2"))
    }

    func test_aStreamThatDoesNotDecodeIsCopiedAsItIs() throws {
        let bad: [UInt8] = [0x78, 0x9C, 0x01, 0x02, 0x03]
        let file = awkward("/Font <</F1 10 0 R>> /XObject <</X 7 0 R>>") { $0.stream(7, "/Filter /FlateDecode", bad) }
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(file), [0], 1)
        let again = try PdfDocument.open(try target.saveRewrite())
        let stream = try XCTUnwrap(again.resolve(again.dict(again.pages[1].resources, "XObject")?["X"]) as? PdfStream)
        XCTAssertEqual(again.rawData(stream), bad)
    }

    func test_aPageWhoseContentCannotBeReadKeepsAllItsResources() throws {
        let bad: [UInt8] = [0x78, 0x9C, 0x01, 0x02, 0x03]
        let file = TestPdf.replace(awkward("/Font <</F1 10 0 R /F9 10 0 R>>") { $0.stream(7, "/Filter /FlateDecode", bad) },
                                   "/Contents 5 0 R", "/Contents 7 0 R")
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, try PdfDocument.open(file), [0], 1)
        XCTAssertTrue(try XCTUnwrap(target.pages[1].resources).containsKey("Font"))
        XCTAssertEqual(target.dict(target.pages[1].resources, "Font")?.count, 2)
    }

    func test_aDamagedSourceStillGivesItsPages() throws {
        let file = PageImportTests.source()
        let cut = Array(file.dropLast(40))
        let source = try PdfDocument.open(cut)
        let target = try PageTestFiles.open(1)
        try PageOperations.importPages(target, source, [0, 1, 2], 1)
        XCTAssertEqual(target.pages.count, 4)
        XCTAssertEqual(try PdfDocument.open(try target.saveRewrite()).repairs, [])
    }
}
