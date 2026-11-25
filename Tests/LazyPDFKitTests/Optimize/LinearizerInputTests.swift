import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/LinearizerInputTests.cs: the same cases.

final class LinearizerInputTests: XCTestCase {
    func test_everyLayoutOfSourceFileLinearizes() throws {
        for kind in ["table", "stream", "hybrid", "objects", "aes128", "aes256objects"] {
            let source = try PdfDocument.open(try SaveFixtures.make(kind))
            let file = try source.saveLinearized(PdfSaveOptions(security: source.security))
            try LinearizerKit.verify(file)
            let again = try PdfDocument.open(file)
            XCTAssertEqual(SaveFixtures.pageTwo, Latin1.string(again.pages[1].contents()), kind)
            XCTAssertEqual(source.isEncrypted, again.isEncrypted, kind)
        }
    }

    func test_objectStreamsAreNotUsed() throws {
        let source = try PdfDocument.open(try SaveFixtures.make("objects"))
        let file = try source.saveLinearized(PdfSaveOptions(useObjectStreams: true))
        let text = Latin1.string(file)
        XCTAssertFalse(text.contains("/ObjStm"))
        XCTAssertFalse(text.contains("/XRef"))
        try LinearizerKit.verify(file)
    }

    func test_aRepairedFileLinearizes() throws {
        let whole = LinearizerKit.make(6)
        let damaged = Array(whole[0..<whole.count - 60])
        let source = try PdfDocument.open(damaged)
        XCTAssertFalse(source.repairs.isEmpty)
        let file = try source.saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        XCTAssertTrue(again.repairs.isEmpty)
        XCTAssertEqual(6, again.pages.count)
    }

    func test_referencesToNothingAreDropped() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Names 77 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 88 0 R] /Count 2>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /MediaBox [0 0 50 50] /Contents [4 0 R 99 0 R] /Annots [66 0 R]>>")
        pdf.stream(4, "", "0 0 m")
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        XCTAssertEqual(1, again.pages.count)
    }

    func test_aStreamWithAWrongLengthIsStoredWithTheLengthItHas() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 50 50]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>")
        pdf.stream(4, "", "0 0 m 10 10 l S", length: 3)
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        XCTAssertEqual("0 0 m 10 10 l S", Latin1.string(again.pages[0].contents()))
        XCTAssertTrue(again.repairs.isEmpty)
    }

    func test_streamDataIsCopiedAsItIs() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 50 50]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</XObject <</Im 5 0 R>>>>>>")
        pdf.stream(4, "", "q /Im Do Q")
        pdf.stream(5, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /Filter /FlateDecode /BitsPerComponent 8", [1, 2, 3, 4, 5])
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        let again = try PdfDocument.open(file)
        let image = try XCTUnwrap(again.resolve(again.dict(again.pages[0].resources, "XObject")?["Im"]) as? PdfStream)
        XCTAssertEqual([1, 2, 3, 4, 5], again.rawData(image))
        try LinearizerKit.verify(file)
    }

    func test_anIntegerBeyondSixtyFourBitsIsWrittenAsAReal() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 50 50]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Big 340282346638528859811704183484516925440 /Small 12>>")
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        let page = again.pages[0].dictionary
        XCTAssertEqual("340282346638528859811704183484516925440.0", (page["Big"] as? PdfNumber)?.text)
        XCTAssertEqual("12", (page["Small"] as? PdfNumber)?.text)
    }

    func test_aLoopInTheParentChainEnds() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 50 50] /Parent 2 0 R>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        XCTAssertEqual(50, again.pages[0].mediaBox.width)
    }

    func test_aPageListedTwiceIsWrittenOnce() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 3 0 R 4 0 R] /Count 3 /MediaBox [0 0 50 50]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R>>")
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        let parameters = try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        XCTAssertEqual(2, parameters["N"])
        XCTAssertEqual(2, again.integer(again.dict(again.catalog, "Pages"), "Count"))
        XCTAssertTrue(again.repairs.isEmpty)
    }

    func test_aCleanNestedTreeKeepsItsShape() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 3 /MediaBox [0 0 50 50]>>")
        pdf.obj(3, "<</Type /Pages /Parent 2 0 R /Kids [5 0 R 6 0 R] /Count 2>>")
        pdf.obj(4, "<</Type /Pages /Parent 2 0 R /Kids [7 0 R] /Count 1>>")
        for i in 0..<3 { pdf.obj(5 + i, "<</Type /Page /Parent \(i < 2 ? 3 : 4) 0 R>>") }
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        XCTAssertEqual(2, again.array(again.dict(again.catalog, "Pages"), "Kids")?.items.count)
        XCTAssertEqual(3, again.pages.count)
    }

    func test_aWrongCountInTheTreeIsMadeRight() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 9 /MediaBox [0 0 50 50]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R>>")
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        XCTAssertEqual(2, again.integer(again.dict(again.catalog, "Pages"), "Count"))
        XCTAssertTrue(again.repairs.isEmpty)
    }

    func test_contentStreamsThePagesShareAreLeftOutOfTheContentSpan() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 50 50]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents [6 0 R 7 0 R]>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents [7 0 R 8 0 R]>>")
        pdf.obj(5, "<</Type /Page /Parent 2 0 R /Contents 7 0 R>>")
        pdf.stream(6, "", "q Q")
        pdf.stream(7, "", "0 0 m")
        pdf.stream(8, "", "1 1 m")
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        try LinearizerKit.verify(file)
        let again = try PdfDocument.open(file)
        XCTAssertEqual("0 0 m", Latin1.string(again.pages[2].contents()))
    }

    func test_manyPagesWithSharedResourcesAreDescribedExactly() throws {
        let file = try PdfDocument.open(LinearizerKit.make(300)).saveLinearized()
        let parameters = try LinearizerKit.verify(file)
        XCTAssertEqual(300, parameters["N"])
    }

    func test_thumbnailsStayOutOfThePagesSections() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 50 50]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Thumb 6 0 R /Contents 5 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Thumb 7 0 R /Contents 5 0 R>>")
        pdf.stream(5, "", "0 0 m")
        pdf.stream(6, "/Width 1 /Height 1 /BitsPerComponent 8", "a")
        pdf.stream(7, "/Width 1 /Height 1 /BitsPerComponent 8", "b")
        let file = try PdfDocument.open(pdf.finish()).saveLinearized()
        let parameters = try LinearizerKit.verify(file)
        XCTAssertTrue(OptimizeKit.indexOf(file, Latin1.bytes("/Width 1")) > (parameters["E"] ?? 0))
    }

    func test_aFileSavedThroughTheSafeSaverStaysLinearized() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("lazypdf-lin.pdf").path
        try Data(LinearizerKit.make(3)).write(to: URL(fileURLWithPath: path))
        let document = try PdfDocument.open(path: path)
        let file = try document.saveLinearized()
        try PdfFileSaver.save(path, file)
        let again = try PdfDocument.open(path: path)
        XCTAssertTrue(again.isLinearized)
    }
}
