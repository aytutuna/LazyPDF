import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/ContentResourcesTests.cs: the same cases, except the PdfPig assertion
// of ARgbaImageDrawsAndReopensInPdfPig (the rest of that test stays). The ArgumentException of
// OpaqueImagesHaveNoMask is a thrown PdfReadException here, since a codec can hand over a frame that does not fit.

final class ContentResourcesTests: XCTestCase {
    func test_inheritedResourcesAreCopiedOntoThePage() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 100] /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(5, ContentTestPdf.helvetica)
        let document = try PdfDocument.open(pdf.finish())

        let resources = ContentResources.forEdit(document, document.pages[0])
        let name = ContentResources.add(document, resources, "ExtGState", PdfDictionary(), "GS")
        XCTAssertEqual(name, "GS1")
        XCTAssertEqual(ContentResources.add(document, resources, "ExtGState", PdfDictionary(), "GS"), "GS2")
        XCTAssertNotNil(document.pages[0].resources?["Font"])
        XCTAssertNil(document.pages[1].resources?["ExtGState"])
        assertSame(resources, ContentResources.forEdit(document, document.pages[0]))
    }

    func test_namesSkipThoseInUse() throws {
        let document = try ContentTestPdf.page("", "/Font <</F1 5 0 R /F2 5 0 R>>", [ContentTestPdf.helvetica])
        let resources = ContentResources.forEdit(document, document.pages[0])
        XCTAssertEqual(ContentResources.add(document, resources, "Font", PdfReference(5, 0), "F"), "F3")
    }

    func test_aRgbaImageDrawsAndReopensInPdfPig() throws {
        let document = try PdfDocument.open(TestPdf.simple(1))
        var rgba = [UInt8](repeating: 0, count: 4 * 4 * 3)
        for i in 0..<12 {
            rgba[4 * i] = UInt8(i * 20)
            rgba[4 * i + 3] = i == 0 ? 128 : 255
        }
        let image = try ContentImages.addRgba(document, 4, 3, rgba)
        let page = document.pages[0]
        let name = ContentResources.add(document, ContentResources.forEdit(document, page), "XObject", image, "Im")
        let content = ContentWriter().paint(name, PdfMatrix(100, 0, 0, 75, 20, 30))
        page.dictionary["Contents"] = try document.add(PdfStream(PdfDictionary(), data: content.toArray()))
        let file = try document.saveRewrite()

        let reopened = try PdfDocument.open(file)
        let r = ContentTestPdf.run(reopened)
        XCTAssertEqual(r.images.count, 1)
        let placed = try XCTUnwrap(r.images.first)
        XCTAssertEqual(placed.bounds, PdfRect(20, 30, 120, 105))
        XCTAssertEqual(placed.width, 4)
        XCTAssertEqual(placed.height, 3)
        XCTAssertNotNil(reopened.resolve(placed.dictionary["SMask"]))
    }

    func test_opaqueImagesHaveNoMask() throws {
        let document = try PdfDocument.open(TestPdf.simple(1))
        let reference = try ContentImages.addRgba(document, 1, 1, [1, 2, 3, 255])
        XCTAssertNil((document.resolve(reference) as? PdfStream)?.dictionary["SMask"])
        XCTAssertThrowsError(try ContentImages.addRgba(document, 2, 2, [1, 2, 3]))
    }

    func test_jpegHeaderGivesSizeAndSpace() throws {
        let document = try PdfDocument.open(TestPdf.simple(1))
        let jpeg: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x20, 0x03,
            1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xFF, 0xD9,
        ]
        let reference = try XCTUnwrap(try ContentImages.addJpeg(document, jpeg))
        let image = try XCTUnwrap(document.resolve(reference) as? PdfStream)
        XCTAssertEqual(document.integer(image.dictionary, "Width"), 32)
        XCTAssertEqual(document.integer(image.dictionary, "Height"), 16)
        XCTAssertEqual(document.name(image.dictionary, "ColorSpace"), "DeviceRGB")
        XCTAssertEqual(document.name(image.dictionary, "Filter"), "DCTDecode")
        XCTAssertNil(try ContentImages.addJpeg(document, [1, 2, 3, 4, 5]))
    }
}
