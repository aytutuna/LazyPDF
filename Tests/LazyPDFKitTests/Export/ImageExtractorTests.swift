import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/ImageExtractorTests.cs: the same cases.

final class ImageExtractorTests: XCTestCase {
    private let fonts = "/XObject <</Jpg 10 0 R /Alpha 11 0 R /Jpx 13 0 R /Jbig 14 0 R /Broken 15 0 R /Masked 16 0 R /Frm 17 0 R /Huge 18 0 R>>"

    private let rgb2x2: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]

    private func open(_ content: String) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <<\(fonts)>> /Contents 30 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Resources <<\(fonts)>> /Contents 31 0 R>>")
        pdf.stream(10, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", ExportKit.jpeg)
        pdf.stream(11, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 12 0 R", TestPdf.deflate(rgb2x2))
        pdf.stream(12, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([0, 85, 170, 255]))
        pdf.stream(13, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode", [1, 2, 3])
        pdf.stream(14, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode", [1, 2, 3])
        pdf.stream(15, "/Type /XObject /Subtype /Image /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8", rgb2x2)
        pdf.stream(16, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /SMask 12 0 R", ExportKit.jpeg)
        pdf.stream(17, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <<" + fonts + ">>", "q 50 0 0 50 0 0 cm /Alpha Do Q")
        pdf.stream(18, "/Type /XObject /Subtype /Image /Width 100000 /Height 100000 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([0, 0]))
        pdf.stream(30, "", content)
        pdf.stream(31, "", "q 20 0 0 20 0 0 cm /Alpha Do Q")
        return try PdfDocument.open(pdf.finish())
    }

    func test_aJpegIsKeptAsItsBytes() throws {
        let found = try ImageExtractor.extract(open("q 80 0 0 60 10 10 cm /Jpg Do Q"), [0])
        XCTAssertEqual(found.count, 1)
        let image = found[0]
        XCTAssertEqual(image.pageIndex, 0)
        XCTAssertEqual(image.name, "Jpg")
        XCTAssertEqual(image.fileName, "page1_Jpg.jpg")
        XCTAssertTrue(image.image.isJpeg)
        XCTAssertEqual(image.image.data, ExportKit.jpeg)
        XCTAssertEqual([image.image.width, image.image.height], [8, 6])
    }

    func test_otherImagesBecomePngWithTheMaskAsAlpha() throws {
        let found = try ImageExtractor.extract(open("q 80 0 0 60 10 10 cm /Alpha Do Q"), [0])
        XCTAssertEqual(found.count, 1)
        let image = found[0].image
        XCTAssertFalse(image.isJpeg)
        let (w, h, rgba) = try ExportKit.pngDecode(image.data)
        XCTAssertEqual([w, h], [2, 2])
        XCTAssertEqual(Array(rgba[0..<4]), [255, 0, 0, 0])
        XCTAssertEqual(Array(rgba[4..<8]), [0, 255, 0, 85])
        XCTAssertEqual(Array(rgba[8..<12]), [0, 0, 255, 170])
        XCTAssertEqual(Array(rgba[12..<16]), [255, 255, 0, 255])
    }

    func test_anImagePaintedTwiceIsListedOnceAndOneInAFormToo() throws {
        let found = try ImageExtractor.extract(open("q 80 0 0 60 10 10 cm /Alpha Do Q q 80 0 0 60 10 10 cm /Alpha Do Q q /Frm Do Q"), [0])
        XCTAssertEqual(found.map { $0.name }, ["Alpha"])
    }

    func test_everyPageIsWalkedAndKeepsItsNumber() throws {
        let found = try ImageExtractor.extract(open("q 80 0 0 60 10 10 cm /Jpg Do Q"))
        XCTAssertEqual(found.map { $0.pageIndex }, [0, 1])
        XCTAssertEqual(found.map { $0.name }, ["Jpg", "Alpha"])
    }

    func test_withoutACodecJpeg2000AndJbig2AreLeftOutAndABrokenImageToo() throws {
        let found = try ImageExtractor.extract(open("q /Jpx Do /Jbig Do /Broken Do /Jpg Do Q"), [0])
        XCTAssertEqual(found.map { $0.name }, ["Jpg"])
    }

    func test_aCodecDecodesThoseAndAJpegWithAMaskGoesThroughIt() throws {
        let codec = ExportFakeCodec()
        let found = try ImageExtractor.extract(open("q /Jpx Do /Jbig Do /Masked Do Q"), [0], codec)
        XCTAssertEqual(found.map { $0.name }, ["Jpx", "Jbig", "Masked"])
        for f in found { XCTAssertFalse(f.image.isJpeg) }
        XCTAssertEqual(codec.decoded, ["JPXDecode", "JBIG2Decode", "DCTDecode"])
        let masked = try ExportKit.pngDecode(found[2].image.data)
        XCTAssertEqual(masked.rgba.enumerated().filter { $0.offset % 4 == 3 }.prefix(4).map { $0.element }, [0, 85, 170, 255])
    }

    func test_aJpegWithAMaskStaysAJpegWithoutACodec() throws {
        let found = try ImageExtractor.extract(open("q /Masked Do Q"), [0])
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].image.isJpeg)
    }

    func test_inlineImagesGetNamesOfTheirOwn() throws {
        let content = "q 40 0 0 40 0 0 cm BI /W 2 /H 2 /CS /RGB /BPC 8 ID " + TestPdf.text(rgb2x2) + " EI Q"
        let found = try ImageExtractor.extract(open(content), [0])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].name, "inline1")
        XCTAssertEqual(Array(try ExportKit.pngDecode(found[0].image.data).rgba[0..<4]), [255, 0, 0, 255])
    }

    func test_anImageTooBigToDecodeIsLeftOut() throws {
        let found = try ImageExtractor.extract(open("q /Huge Do /Jpg Do Q"), [0])
        XCTAssertEqual(found.map { $0.name }, ["Jpg"])
    }

    func test_aBadPageIndexIsRefusedAndCancellationHonoured() async throws {
        let document = try open("")
        XCTAssertThrowsError(try ImageExtractor.extract(document, [2])) { XCTAssertTrue($0 is ArgumentException) }
        let task = Task { () -> [ExportedImage] in
            while !Task.isCancelled { await Task.yield() }
            return try ImageExtractor.extract(document)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_aDocumentWithoutImagesGivesNone() throws {
        XCTAssertTrue(try ImageExtractor.extract(ExportKit.open("BT /F1 12 Tf 72 700 Td (text) Tj ET")).isEmpty)
    }
}
