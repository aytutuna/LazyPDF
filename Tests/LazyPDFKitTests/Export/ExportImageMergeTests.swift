import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/ExportImageMergeTests.cs: the same cases. A cancelled run is the cancelled task.

/// Hands back the same RGBA pixels for every coded stream it is asked to read.
final class ExportRgbaCodec: ImageCodec {
    private let width: Int
    private let rgba: [UInt8]

    init(_ width: Int, _ rgba: UInt8...) {
        self.width = width
        self.rgba = rgba
    }

    init(_ width: Int, _ rgba: [UInt8]) {
        self.width = width
        self.rgba = rgba
    }

    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { PdfRgbaImage(width, rgba.count / 4 / width, rgba) }

    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { nil }

    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
}

/// Reports an image of the given size without holding any pixels.
final class ExportSizedCodec: ImageCodec {
    private let width: Int
    private let height: Int

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { PdfRgbaImage(width, height, []) }

    func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? { nil }

    func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
}

final class ExportImageMergeTests: XCTestCase {
    private let image = "/Type /XObject /Subtype /Image"
    private let cmykJpeg = "/Width 1 /Height 1 /ColorSpace /DeviceCMYK /BitsPerComponent 8 /Filter /DCTDecode"
    private let reversed = "/Decode [1 0 1 0 1 0 1 0]"

    // A JPEG that stops after its Adobe marker; the export only reads the header.
    private let adobe: [UInt8] = [0xFF, 0xD8, 0xFF, 0xEE, 0, 14, UInt8(ascii: "A"), UInt8(ascii: "d"), UInt8(ascii: "o"), UInt8(ascii: "b"), UInt8(ascii: "e"), 0, 100, 0, 0, 0, 0, 0, 0xFF, 0xDA]

    private func open(_ content: String, _ objects: (TestPdf) -> Void, resources: String = "/XObject <</Im 10 0 R>>", pageEntries: String = "") throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R \(pageEntries) /Resources <<\(resources)>> /Contents 30 0 R>>")
        pdf.stream(30, "", content)
        objects(pdf)
        return try PdfDocument.open(pdf.finish())
    }

    private func extract(_ entries: String, _ data: [UInt8], _ codec: ImageCodec?, _ more: ((TestPdf) -> Void)? = nil) throws -> ExportImage? {
        let document = try open("q 10 0 0 10 0 0 cm /Im Do Q") { pdf in
            pdf.stream(10, "\(image) \(entries)", data)
            more?(pdf)
        }
        return try ImageExtractor.extract(document, nil, codec).first?.image
    }

    private func rgba(_ image: ExportImage?) throws -> [UInt8] {
        try ExportKit.pngDecode(XCTUnwrap(image).data).rgba
    }

    private func alphas(_ rgba: [UInt8]) -> [UInt8] { rgba.enumerated().filter { $0.offset % 4 == 3 }.map { $0.element } }

    func test_aColourSpaceThatIsAStreamSkipsTheImageInsteadOfAbortingTheRun() throws {
        let document = try open("q 10 0 0 10 0 0 cm BI /W 1 /H 1 /CS /Cs1 /BPC 8 ID x EI Q", { $0.stream(11, "", "abc") }, resources: "/ColorSpace <</Cs1 11 0 R>>")
        XCTAssertTrue(try ImageExtractor.extract(document).isEmpty)
        XCTAssertTrue(try ExportLayout.analyze(document).pages[0].pictures.isEmpty)
    }

    func test_aCmykJpegThatReadsTheSameWithOrWithoutTheCodecStaysAFile() throws {
        let codec = ExportRgbaCodec(1, 200, 100, 50, 255)
        XCTAssertTrue(try XCTUnwrap(extract("\(cmykJpeg) \(reversed)", adobe, codec)).isJpeg)
        XCTAssertTrue(try XCTUnwrap(extract(cmykJpeg, [1], codec)).isJpeg)
    }

    func test_anAdobeCmykJpegWithItsReversingDecodeIsNotReversedAgain() throws {
        let png = try extract("\(cmykJpeg) \(reversed) /Mask [255 255 255 255 255 255 255 255]", adobe, ExportRgbaCodec(1, 200, 100, 50, 255))
        XCTAssertEqual(try rgba(png), [200, 100, 50, 255])
    }

    func test_aCmykJpegWhoseMarkerAndDecodeDisagreeIsShownAsThePageShowsIt() throws {
        for (decode, marked) in [("", true), ("/Decode [1 0 1 0 1 0 1 0]", false)] {
            let png = try extract("\(cmykJpeg) \(decode)", marked ? adobe : [1], ExportRgbaCodec(1, 200, 100, 50, 255))
            XCTAssertEqual(try rgba(png), [55, 155, 205, 255], "decode \"\(decode)\"")
        }
    }

    func test_aColourKeyOnACmykJpegIsMatchedAgainstTheRgbOfItsInks() throws {
        let png = try extract("\(cmykJpeg) /Mask [0 0 0 0 0 0 0 0]", [1], ExportRgbaCodec(2, 255, 255, 255, 255, 0, 0, 0, 255))
        XCTAssertEqual(alphas(try rgba(png)), [0, 255])
    }

    func test_aDecodeArrayOnAJpxImageIsIgnored() throws {
        let png = try extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode /Decode [1 0 1 0 1 0]", [1], ExportRgbaCodec(1, 10, 20, 30, 255))
        XCTAssertEqual(try rgba(png), [10, 20, 30, 255])
    }

    func test_aJpxImageKeepsItsOwnAlphaOnlyWhenTheFileAsksFor() throws {
        let codec = ExportRgbaCodec(1, 10, 20, 30, 40)
        XCTAssertEqual(try rgba(extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode /SMaskInData 1", [1], codec)), [10, 20, 30, 40])
        XCTAssertEqual(try rgba(extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode", [1], codec)), [10, 20, 30, 255])
    }

    func test_aColourKeyOnABilevelCodecImageMatchesItsOwnDepth() throws {
        let png = try extract("/Width 2 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode /Mask [1 1]", [1], ExportPixelCodec(2, 0, 255))
        XCTAssertEqual(alphas(try rgba(png)), [255, 0])
    }

    func test_anIndexedBilevelCodecImageReadsItsPaletteByTheStoredSample() throws {
        let png = try extract("/Width 2 /Height 1 /ColorSpace [/Indexed /DeviceRGB 3 <000000 FF0000 00FF00 0000FF>] /BitsPerComponent 1 /Filter /JBIG2Decode", [1],
                              ExportPixelCodec(2, 0, 255))
        XCTAssertEqual(try rgba(png), [0, 0, 0, 255, 255, 0, 0, 255])
    }

    func test_aSoftMaskWithTheShortFilterNameIsReadThroughTheCodec() throws {
        let png = try extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 11 0 R", TestPdf.deflate([9, 8, 7]), ExportPixelCodec(1, 128)) { pdf in
            pdf.stream(11, "\(self.image) /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCT", [1])
        }
        XCTAssertEqual(try rgba(png), [9, 8, 7, 128])
    }

    func test_aDecodedImageWithAnUnreadableColourSpaceIsStillExported() throws {
        let png = try extract("/Width 1 /Height 1 /ColorSpace [/CalCMYK <<>>] /Filter /JPXDecode", [1], ExportRgbaCodec(1, 10, 20, 30, 255))
        XCTAssertEqual(try rgba(png), [10, 20, 30, 255])
    }

    func test_theAlphaOfAJpxImageWithAnUnreadableColourSpaceFollowsSMaskInData() throws {
        let codec = ExportRgbaCodec(1, 10, 20, 30, 40)
        XCTAssertEqual(try rgba(extract("/Width 1 /Height 1 /ColorSpace [/CalCMYK <<>>] /Filter /JPXDecode", [1], codec)), [10, 20, 30, 255])
        XCTAssertEqual(try rgba(extract("/Width 1 /Height 1 /ColorSpace [/CalCMYK <<>>] /Filter /JPXDecode /SMaskInData 1", [1], codec)), [10, 20, 30, 40])
    }

    func test_premultipliedJpxAlphaIsUndone() throws {
        let png = try extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode /SMaskInData 2", [1], ExportRgbaCodec(1, 10, 20, 30, 128))
        XCTAssertEqual(try rgba(png), [20, 40, 60, 128])
    }

    func test_aCodedSoftMaskBesideAMaskStreamLeavesTheMaskStreamUnread() throws {
        let png = try extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask 11 0 R /Mask 12 0 R", TestPdf.deflate([9, 8, 7]), ExportPixelCodec(1, 128)) { pdf in
            pdf.stream(11, "\(self.image) /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /JPXDecode", [1])
            pdf.stream(12, "\(self.image) /Width 1 /Height 1 /ImageMask true /Filter /JBIG2Decode", [1])
        }
        XCTAssertEqual(try rgba(png), [9, 8, 7, 128])
    }

    func test_anUnreadableMaskLeavesACodecImageOpaque() throws {
        let png = try extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode /SMask 11 0 R", [1], ExportRgbaCodec(1, 10, 20, 30, 255)) { pdf in
            pdf.stream(11, "\(self.image) /Width 0 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([0]))
        }
        XCTAssertEqual(try rgba(png), [10, 20, 30, 255])
    }

    func test_anUnreadableMaskLeavesAJpegWithoutACodecAsItsBytes() throws {
        let png = try extract("/Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /SMask 11 0 R", [1], nil) { pdf in
            pdf.stream(11, "\(self.image) /Width 0 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([0]))
        }
        XCTAssertTrue(try XCTUnwrap(png).isJpeg)
    }

    private func infos(_ document: PdfDocument) -> [ImageInfo] {
        let scan = ExportScan(PageGeometry(document.pages[0]), false)
        ContentInterpreter(document).run(document.pages[0], scan)
        return scan.images
    }

    private func flate(_ count: Int, _ extra: String = "", _ more: ((TestPdf) -> Void)? = nil) throws -> PdfDocument {
        let content = (0..<count).map { "/Im\($0) Do " }.joined()
        let resources = "/XObject <<" + (0..<count).map { "/Im\($0) \(10 + $0) 0 R " }.joined() + ">>"
        return try open(content, { pdf in
            for i in 0..<count {
                pdf.stream(10 + i, "\(self.image) /Width 10 /Height 10 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode \(extra)", TestPdf.deflate([UInt8](repeating: 0, count: 100)))
            }
            more?(pdf)
        }, resources: resources)
    }

    private func maskObject(_ number: Int, _ entries: String, _ data: [UInt8]) -> (TestPdf) -> Void {
        { pdf in pdf.stream(number, "\(self.image) \(entries)", data) }
    }

    func test_onlyPixelsThatAreDecodedUseUpThePixelBudget() throws {
        let document = try open("/Big Do /Small Do", { pdf in
            pdf.stream(10, "\(self.image) /Width 1000 /Height 1000 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", [1])
            pdf.stream(11, "\(self.image) /Width 10 /Height 10 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([UInt8](repeating: 0, count: 100)))
        }, resources: "/XObject <</Big 10 0 R /Small 11 0 R>>")
        let list = infos(document)
        let images = ExportImages(document, nil, pixelBudget: 100)
        XCTAssertNotNil(try images.get(list[0], 6))
        XCTAssertNotNil(try images.get(list[0]))
        XCTAssertNotNil(try images.get(list[1]))
    }

    func test_imagesPastThePixelBudgetAreLeftOut() throws {
        let document = try flate(5)
        let images = ExportImages(document, nil, pixelBudget: 250)
        XCTAssertEqual(try infos(document).map { try images.get($0) != nil }, [true, true, false, false, false])
    }

    func test_aMaskSharedByManyImagesIsChargedForEachDecode() throws {
        let document = try flate(8, "/SMask 40 0 R", maskObject(40, "/Width 10 /Height 10 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([UInt8](repeating: 0, count: 100))))
        let images = ExportImages(document, nil, pixelBudget: 450)
        XCTAssertEqual(try infos(document).filter { try images.get($0) != nil }.count, 2)
    }

    func test_aCancelledRunStopsBeforeTheNextDecode() async throws {
        let document = try flate(2)
        let images = ExportImages(document, nil)
        let list = infos(document)
        XCTAssertNotNil(try images.get(list[0]))
        let task = Task { () -> ExportImage? in
            while !Task.isCancelled { await Task.yield() }
            return try images.get(list[1])
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_jpegScansOnRotatedPagesAreNotLostToThePixelBudget() throws {
        let pdf = TestPdf()
        let pages = 40
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [\((0..<pages).map { "\(100 + $0) 0 R" }.joined(separator: " "))] /Count \(pages) /MediaBox [0 0 612 792] /Rotate 90>>")
        for i in 0..<pages {
            pdf.obj(100 + i, "<</Type /Page /Parent 2 0 R /Resources <</XObject <</Im \(200 + i) 0 R>>>> /Contents \(300 + i) 0 R>>")
            pdf.stream(300 + i, "", "q 612 0 0 792 0 0 cm /Im Do Q")
            pdf.stream(200 + i, "\(image) /Width 2550 /Height 3300 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", [1])
        }
        let result = try ExportLayout.analyze(PdfDocument.open(pdf.finish()))
        for p in result.pages { XCTAssertEqual(p.pictures.count, 1) }
    }

    func test_aRotatedJpegPastTheLimitsStaysAJpeg() throws {
        let document = try open("/Im Do", { $0.stream(10, "\(self.image) /Width 100 /Height 100 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", [1]) })
        let images = ExportImages(document, ExportRgbaCodec(4, [UInt8](repeating: 0, count: 64)), pixelBudget: 10)
        XCTAssertTrue(try XCTUnwrap(try images.get(infos(document)[0], 6)).isJpeg)
    }

    func test_aMaskOfAbsurdSizeDoesNotSpendOrCreditThePixelBudget() throws {
        for size in ["/Width 100000 /Height 100000", "/Width -1000000 /Height 1000000"] {
            let content = (0..<6).map { "/Im\($0) Do " }.joined()
            let resources = "/XObject <<" + (0..<6).map { "/Im\($0) \(10 + $0) 0 R " }.joined() + ">>"
            let document = try open(content, { pdf in
                pdf.stream(40, "\(self.image) \(size) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([UInt8](repeating: 0, count: 100)))
                for i in 0..<6 {
                    let mask = i == 0 ? "/SMask 40 0 R" : ""
                    pdf.stream(10 + i, "\(self.image) /Width 10 /Height 10 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode \(mask)", TestPdf.deflate([UInt8](repeating: 0, count: 100)))
                }
            }, resources: resources)
            let images = ExportImages(document, nil, pixelBudget: 250)
            XCTAssertEqual(try infos(document).filter { try images.get($0) != nil }.count, 1, size)
        }
    }

    func test_aCodecImageIsChargedForThePixelsItDecodesTo() throws {
        let document = try open("/A Do /B Do /C Do", { pdf in
            for id in [10, 11, 12] { pdf.stream(id, "\(self.image) /Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode", [UInt8(id)]) }
        }, resources: "/XObject <</A 10 0 R /B 11 0 R /C 12 0 R>>")
        let images = ExportImages(document, ExportRgbaCodec(10, [UInt8](repeating: 0, count: 400)), pixelBudget: 150)
        XCTAssertEqual(try infos(document).map { try images.get($0) != nil }, [true, false, false])
    }

    func test_aCodecImageDecodedPastTheSizeLimitIsStillCharged() throws {
        let document = try open("/A Do /B Do", { pdf in
            pdf.stream(10, "\(self.image) /Width 1 /Height 1 /ColorSpace /DeviceRGB /Filter /JPXDecode", [1])
            pdf.stream(11, "\(self.image) /Width 10 /Height 10 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([UInt8](repeating: 0, count: 100)))
        }, resources: "/XObject <</A 10 0 R /B 11 0 R>>")
        let images = ExportImages(document, ExportSizedCodec(9000, 9000), pixelBudget: 81_000_050)
        XCTAssertEqual(try infos(document).map { try images.get($0) != nil }, [false, false])
    }

    func test_aSizeThatWrapsDoesNotCreditThePixelBudget() throws {
        let content = (0..<7).map { "/Im\($0) Do " }.joined()
        let resources = "/XObject <<" + (0..<7).map { "/Im\($0) \(10 + $0) 0 R " }.joined() + ">>"
        let document = try open(content, { pdf in
            for i in 0..<7 {
                let size = i == 0 ? "/Width 3037000500 /Height 3037000500" : "/Width 10 /Height 10"
                pdf.stream(10 + i, "\(self.image) \(size) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([UInt8](repeating: 0, count: 100)))
            }
        }, resources: resources)
        let images = ExportImages(document, nil, pixelBudget: 250)
        XCTAssertEqual(try infos(document).filter { try images.get($0) != nil }.count, 2)
    }

    func test_aMaskSizedByTheShortKeysIsChargedForItsPixels() throws {
        let document = try flate(5, "/SMask 40 0 R", maskObject(40, "/W 1000 /H 1000 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", TestPdf.deflate([UInt8](repeating: 0, count: 10))))
        let images = ExportImages(document, nil, pixelBudget: 2_500_000)
        XCTAssertEqual(try infos(document).filter { try images.get($0) != nil }.count, 2)
    }

    func test_aCodedMaskIsChargedForThePixelsTheCodecReturns() throws {
        let document = try flate(1, "/SMask 40 0 R", maskObject(40, "/Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /JPXDecode", [1]))
        let images = ExportImages(document, ExportPixelCodec(10, [UInt8](repeating: 0, count: 100)), pixelBudget: 150)
        XCTAssertNil(try images.get(infos(document)[0]))
    }

    func test_aJpegBehindAFilterPastTheByteLimitIsLeftOut() throws {
        let document = try open("/Im Do", { pdf in
            pdf.stream(10, "\(self.image) /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter [/FlateDecode /DCTDecode]", TestPdf.deflate([UInt8](repeating: 0, count: 5000)))
        })
        let images = ExportImages(document, nil, byteLimit: 1000)
        XCTAssertNil(try images.get(infos(document)[0]))
    }

    func test_aJpegBehindAFilterWithinTheByteLimitIsKept() throws {
        let document = try open("/Im Do", { pdf in
            pdf.stream(10, "\(self.image) /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter [/FlateDecode /DCTDecode]", TestPdf.deflate([UInt8](repeating: 0, count: 500)))
        })
        let images = ExportImages(document, nil, byteLimit: 1000)
        XCTAssertEqual(try XCTUnwrap(try images.get(infos(document)[0])).data.count, 500)
    }

    func test_jpegsPastTheByteLimitAreStillKeptAsTheirBytes() throws {
        let document = try open("/A Do /B Do /C Do", { pdf in
            for id in [10, 11, 12] { pdf.stream(id, "\(self.image) /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", [1, 2, 3, 4]) }
        }, resources: "/XObject <</A 10 0 R /B 11 0 R /C 12 0 R>>")
        let images = ExportImages(document, ExportRgbaCodec(1, 1, 2, 3, 255), byteLimit: 3)
        let list = infos(document)
        XCTAssertTrue(try XCTUnwrap(try images.get(list[0])).isJpeg)
        XCTAssertTrue(try XCTUnwrap(try images.get(list[1])).isJpeg)
        XCTAssertTrue(try XCTUnwrap(try images.get(list[2], 6)).isJpeg)
    }

    func test_aSidewaysJpegIsNotStretchedIntoTheTurnedBox() throws {
        let document = try open("q 612 0 0 792 0 0 cm /Im Do Q", { pdf in
            pdf.stream(10, "\(self.image) /Width 612 /Height 792 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", [1])
        }, pageEntries: "/Rotate 90")
        let pictures = try ExportLayout.analyze(document).pages[0].pictures
        XCTAssertEqual(pictures.count, 1)
        XCTAssertTrue(pictures[0].image.isJpeg)
        XCTAssertEqual(pictures[0].bounds.width / pictures[0].bounds.height, 612.0 / 792, accuracy: 0.0005)
    }

    func test_aTinyPictureOnPicturePaperMakesAPage() throws {
        let made = try PdfFromPictures.create([ExportFakeCodec.picture(1, 1)], ExportFakeCodec(), PdfPageSetup(paper: .picture))
        XCTAssertEqual(made.pages, 1)
        XCTAssertThrowsError(try PdfFromPictures.create([ExportFakeCodec.picture(1, 1)], ExportFakeCodec(), PdfPageSetup(paper: .picture, margin: 8000))) {
            XCTAssertTrue($0 is ArgumentException)
        }
    }
}
