import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/ExportImagesTests.cs: the same cases.

/// Hands back the same gray pixels for every coded stream it is asked to read.
final class ExportPixelCodec: ImageCodec {
    private let width: Int
    private let gray: [UInt8]

    init(_ width: Int, _ gray: UInt8...) {
        self.width = width
        self.gray = gray
    }

    init(_ width: Int, _ gray: [UInt8]) {
        self.width = width
        self.gray = gray
    }

    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? {
        var rgba = [UInt8](repeating: 0, count: gray.count * 4)
        for i in 0..<gray.count { (rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2], rgba[4 * i + 3]) = (gray[i], gray[i], gray[i], 255) }
        return PdfRgbaImage(width, gray.count / width, rgba)
    }

    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { nil }

    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
}

final class ExportImagesTests: XCTestCase {
    private let image = "/Type /XObject /Subtype /Image"
    private let ink = "[/Separation /Black /DeviceCMYK <</FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 0 0 1] /N 1>>]"

    private func open(_ content: String, _ objects: (TestPdf) -> Void, _ pageEntries: String = "") throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R \(pageEntries) /Resources <</XObject <</Im 10 0 R>>>> /Contents 30 0 R>>")
        pdf.stream(30, "", content)
        objects(pdf)
        return try PdfDocument.open(pdf.finish())
    }

    private func extract(_ entries: String, _ data: [UInt8], _ codec: ImageCodec?, _ more: ((TestPdf) -> Void)? = nil) throws -> ExportImage {
        let document = try open("q 10 0 0 10 0 0 cm /Im Do Q") { pdf in
            pdf.stream(10, "\(image) \(entries)", data)
            more?(pdf)
        }
        let found = try ImageExtractor.extract(document, nil, codec)
        XCTAssertEqual(found.count, 1)
        return try XCTUnwrap(found.first).image
    }

    private func alpha(_ image: ExportImage) throws -> [UInt8] {
        try ExportKit.pngDecode(image.data).rgba.enumerated().filter { $0.offset % 4 == 3 }.map { $0.element }
    }

    func test_aPictureOverTheSizeLimitIsLeftOutAndCounted() throws {
        let document = try open("q 10 0 0 10 0 0 cm /Im Do Q") { $0.stream(10, "\(image) /Width 10000 /Height 10000 /ColorSpace /DeviceGray /BitsPerComponent 8", [1]) }

        let model = try ExportLayout.analyze(document)

        XCTAssertEqual(model.picturesLeftOut, 1)
        XCTAssertTrue(model.pages[0].pictures.isEmpty)
        XCTAssertEqual(ExportText.picturesLeftOut(1), "1 picture was left out because the file is too large.")
    }

    func test_aPictureThatWasKeptIsNotCounted() throws {
        let document = try open("q 10 0 0 10 0 0 cm /Im Do Q") { $0.stream(10, "\(image) /Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 255]) }

        let model = try ExportLayout.analyze(document)

        XCTAssertEqual(model.picturesLeftOut, 0)
        XCTAssertEqual(model.pages[0].pictures.count, 1)
    }

    func test_aDecodeArrayOnAJpegIsHonoured() throws {
        let png = try extract("/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Decode [1 0]", [1], ExportPixelCodec(2, 0, 200))
        XCTAssertEqual(try ExportKit.pngDecode(png.data).rgba, [255, 255, 255, 255, 55, 55, 55, 255])
    }

    func test_aStencilMaskOnAJpegBecomesAlpha() throws {
        let png = try extract("/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Mask 11 0 R", [1], ExportPixelCodec(2, 90, 90)) { pdf in
            pdf.stream(11, "\(self.image) /Width 2 /Height 1 /ImageMask true /BitsPerComponent 1", [0b0100_0000])
        }
        XCTAssertEqual(try alpha(png), [255, 0])
    }

    func test_anImageMaskKeepsItsDecodePolarityWhateverTheFilter() throws {
        let png = try extract("/Width 2 /Height 1 /ImageMask true /BitsPerComponent 1 /Filter /JBIG2Decode /Decode [1 0]", [1], ExportPixelCodec(2, 0, 255))
        XCTAssertEqual(try alpha(png), [0, 255])
    }

    func test_aColourKeyMaskOnAJpegMakesTheKeyedColourTransparent() throws {
        let png = try extract("/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /Mask [0 10]", [1], ExportPixelCodec(2, 5, 200))
        XCTAssertEqual(try alpha(png), [0, 255])
    }

    func test_aSoftMaskStoredAsJpegIsReadThroughTheCodec() throws {
        let entries = "/Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 11 0 R"
        let mask: (TestPdf) -> Void = { pdf in pdf.stream(11, "\(self.image) /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", [1]) }
        let with = try extract(entries, TestPdf.deflate([9, 8, 7]), ExportPixelCodec(1, 128), mask)
        XCTAssertEqual(try ExportKit.pngDecode(with.data).rgba, [9, 8, 7, 128])
        let without = try extract(entries, TestPdf.deflate([9, 8, 7]), nil, mask)
        XCTAssertEqual(try ExportKit.pngDecode(without.data).rgba, [9, 8, 7, 255])
    }

    func test_aJpegWithAJpxSoftMaskKeepsItsColoursAndTakesTheAlpha() throws {
        let png = try extract("/Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode /SMask 11 0 R", [1], ExportPixelCodec(1, 64)) { pdf in
            pdf.stream(11, "\(self.image) /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /JPXDecode", [1])
        }
        XCTAssertEqual(try ExportKit.pngDecode(png.data).rgba, [64, 64, 64, 64])
    }

    func test_aSeparationJpegIsInkedNotShownAsGray() throws {
        let png = try extract("/Width 1 /Height 1 /ColorSpace \(ink) /BitsPerComponent 8 /Filter /DCTDecode", [1], ExportPixelCodec(1, 255))
        XCTAssertFalse(png.isJpeg)
        XCTAssertLessThan(try ExportKit.pngDecode(png.data).rgba[0], 80)
    }

    func test_aSeparationJpegWithoutACodecStaysAJpeg() throws {
        XCTAssertTrue(try extract("/Width 1 /Height 1 /ColorSpace \(ink) /BitsPerComponent 8 /Filter /DCTDecode", [1], nil).isJpeg)
    }

    func test_anInlineImagePaintedAgainIsDecodedOnce() throws {
        let inline = "q 40 0 0 40 0 0 cm BI /W 2 /H 2 /CS /RGB /BPC 8 ID " + TestPdf.text([255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9]) + " EI Q\n"
        let found = try ImageExtractor.extract(open(String(repeating: inline, count: 5)) { _ in })
        XCTAssertEqual(found.count, 5)
        for f in found { assertSame(found[0].image, f.image) }
    }

    private func rotated(_ pageEntries: String, _ cm: String) throws -> PdfDocument {
        try open("q \(cm) cm /Im Do Q", { pdf in
            pdf.stream(10, "\(image) /Width 2 /Height 3 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([10, 20, 30, 40, 50, 60]))
        }, pageEntries)
    }

    private func onlyPicture(_ document: PdfDocument) throws -> (width: Int, height: Int, gray: [UInt8]) {
        let pictures = try ExportLayout.analyze(document).pages[0].pictures
        XCTAssertEqual(pictures.count, 1)
        let picture = try XCTUnwrap(pictures.first)
        let (w, h, rgba) = try ExportKit.pngDecode(picture.image.data)
        XCTAssertEqual(picture.bounds.width > picture.bounds.height, w > h)
        return (w, h, rgba.enumerated().filter { $0.offset % 4 == 0 }.map { $0.element })
    }

    func test_aPictureOnARotatedPageIsTurnedToMatchItsBox() throws {
        let (w, h, gray) = try onlyPicture(rotated("/Rotate 90", "200 0 0 300 100 100"))
        XCTAssertEqual([w, h], [3, 2])
        XCTAssertEqual(gray, [50, 30, 10, 60, 40, 20])
    }

    func test_aMirroredPictureIsMirroredInTheExport() throws {
        let (w, h, gray) = try onlyPicture(rotated("", "-200 0 0 300 300 100"))
        XCTAssertEqual([w, h], [2, 3])
        XCTAssertEqual(gray, [20, 10, 40, 30, 60, 50])
    }

    func test_anUprightPictureIsLeftAlone() throws {
        XCTAssertEqual(try onlyPicture(rotated("", "200 0 0 300 100 100")).gray, [10, 20, 30, 40, 50, 60])
    }

    func test_aNameFromTheFileCannotLeaveTheOutputFolder() {
        let image = ExportImage([1], true, 1, 1)
        let file = ExportedImage(0, "../..\\a:b", image).fileName
        XCTAssertFalse(file.contains { $0 == "/" || $0 == "\\" || $0 == ":" })
        XCTAssertEqual(URL(fileURLWithPath: "/folder/" + file).lastPathComponent, file)
    }
}
