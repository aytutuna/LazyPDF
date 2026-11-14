import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/Jbig2CallerTests.cs: what the tools that need pixels make of a JBIG2 image now
// that the filter decodes it. The picture with globals is the golden pair with-globals.bin and globals.bin (64 by 40) where the
// C# makes one with its text encoder; its pixels are what the filter returns for it, which the golden test pins down. A page
// of which one region cannot be decoded is a text region of zeros that refers to a dictionary that is not there.
final class Jbig2CallerTests: XCTestCase {
    private let globalsEntry = "/DecodeParms <</JBIG2Globals 7 0 R>>"

    private func image(_ width: Int, _ height: Int, _ extra: String = "") -> String {
        "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /JBIG2Decode \(extra)"
    }

    private func white(_ size: Int) -> [UInt8] { Jbig2Segments.generic(Bm(size, size), 0, false) }

    private let place = "q 160 0 0 160 100 100 cm /Im1 Do Q"

    // The top left quarter of the image placed as above.
    private func topLeft() -> RedactionMark { RedactionMark.fromRect(0, PdfRect(100, 220, 140, 260)) }

    private func imageStreams(_ document: PdfDocument) -> [PdfStream] {
        document.objectNumbers.compactMap { document.get($0) as? PdfStream }.filter { document.name($0.dictionary, "Subtype") == "Image" }
    }

    func test_redactionZeroesTheMarkedPixelsOfAJbig2Image() throws {
        for globals in [false, true] {
            let data = globals ? try Jbig2Samples.withGlobals() : white(8)
            let shared = try Jbig2Samples.globals()
            let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in
                pdf.stream(6, self.image(globals ? 64 : 8, globals ? 40 : 8, globals ? self.globalsEntry : ""), data)
                if globals { pdf.stream(7, "", shared) }
            }
            let result = try PdfRedactor(document).apply([topLeft()])
            let output = try RedactionKit.open(result)
            let stream = try XCTUnwrap(imageStreams(output).first)
            XCTAssertEqual(imageStreams(output).count, 1)
            XCTAssertEqual(output.name(stream.dictionary, "Filter"), "FlateDecode")
            XCTAssertFalse(stream.dictionary.containsKey("DecodeParms"))
            var expected: [UInt8]
            if globals {
                // The top left 16 by 10 pixels of 64 by 40.
                expected = try Jbig2Samples.withGlobalsPage()
                for y in 0..<10 { expected[y * 8] = 0; expected[y * 8 + 1] = 0 }
            } else {
                // The top left 2 by 2 pixels of 8 by 8.
                expected = [UInt8](repeating: 0xff, count: 8)
                expected[0] = 0x3f
                expected[1] = 0x3f
            }
            XCTAssertEqual(try output.data(stream), expected, "globals \(globals)")
            XCTAssertEqual(result.report.images, 1)
            XCTAssertEqual(result.report.pages[0].wholeImages, 0)
            // Nothing of the coded picture or its globals is left to read the pixels from.
            for number in output.objectNumbers {
                if let s = output.get(number) as? PdfStream { XCTAssertNotEqual(output.name(s.dictionary, "Filter"), "JBIG2Decode") }
            }
            XCTAssertFalse(RedactionKit.holds(result.bytes, "JBIG2Globals"))
        }
    }

    func test_aRedactedJbig2PictureWithAnotherDepthThanOneBitIsRemovedWhole() throws {
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /JBIG2Decode", self.white(8))
        }
        let result = try PdfRedactor(document).apply([topLeft()])
        let output = try RedactionKit.open(result)
        XCTAssertTrue(RedactionKit.images(output).isEmpty)
        XCTAssertEqual(result.report.pages[0].wholeImages, 1)
    }

    func test_aPageOfAnotherSizeIsCutOrPaddedWithWhiteToTheImage() throws {
        let page = Bm.text(8, 8, 17)
        for (width, height) in [(12, 8), (5, 8), (8, 11), (8, 3), (13, 2)] {
            let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in
                pdf.stream(6, self.image(width, height), Jbig2Segments.generic(page, 0, false))
            }
            let found = try XCTUnwrap(try ImageExtractor.extract(document, [0]).first)
            let (w, h, rgba) = try ExportKit.pngDecode(found.image.data)
            XCTAssertEqual(w, width)
            XCTAssertEqual(h, height)
            for y in 0..<h {
                for x in 0..<w { XCTAssertEqual(Int(rgba[(y * w + x) * 4]), page[x, y] != 0 ? 0 : 255, "\(width)x\(height) at \(x),\(y)") }
            }
        }
    }

    func test_aRedactedPictureWhosePageIsNotItsSizeIsCutLikeAnyOther() throws {
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in pdf.stream(6, self.image(16, 16), self.white(8)) }
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(100, 100, 140, 140))])
        let output = try RedactionKit.open(result)
        let samples = try output.data(try XCTUnwrap(imageStreams(output).first))
        XCTAssertEqual(samples.count, 32)
        XCTAssertEqual(samples[0], 0xff)
        XCTAssertEqual(samples[28], 0x0f)
    }

    // A page of which one region is drawn and another, a text region with no dictionary, is not.
    private func partial() -> [UInt8] {
        let e = ArithEncoder()
        Jbig2Encode.generic(e, Bm(8, 8), 0, false)
        return Jbig2Segments.cat(Jbig2Segments.segment(0, 48, Jbig2Segments.pageInfo(8, 8)),
                                 Jbig2Segments.segment(1, 6, Jbig2Segments.cat(Jbig2Segments.regionInfo(8, 8), [UInt8](repeating: 0, count: 16)), [9]),
                                 Jbig2Segments.segment(2, 38, Jbig2Segments.genericData(Bm(8, 8), e.finish(), 0, false, false, nil)))
    }

    func test_aRedactedPictureThatDecodedOnlyInPartIsRemovedWhole() throws {
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in pdf.stream(6, self.image(8, 8), self.partial()) }
        let result = try PdfRedactor(document).apply([topLeft()])
        let output = try RedactionKit.open(result)
        XCTAssertTrue(RedactionKit.images(output).isEmpty)
        XCTAssertEqual(result.report.pages[0].wholeImages, 1)
    }

    func test_exportKeepsAPartialPictureAndMakeSmallerLeavesItAsStored() throws {
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in pdf.stream(6, self.image(8, 8), self.partial()) }
        XCTAssertEqual(try ImageExtractor.extract(document, [0]).count, 1)
        let file = OptimizeKit.build("q 10 0 0 10 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>") { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 1 /Filter /JBIG2Decode", self.partial())
        }
        let source = try PdfDocument.open(file)
        let result = try PdfOptimizer(source).run(OptimizeKit.off.with { $0.imageDpi = 8; $0.imageDpiAbove = 10; $0.bilevelTolerance = 10 })
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual(after.name(try OptimizeKit.image(after).dictionary, "Filter"), "JBIG2Decode")
    }

    func test_makeSmallerSkipsAnImageWhoseGlobalsAreBroken() throws {
        let data = try Jbig2Samples.withGlobals()
        let file = OptimizeKit.build("q 10 0 0 10 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>") { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Image /Width 64 /Height 40 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JBIG2Decode /DecodeParms <</JBIG2Globals 6 0 R>>", data)
            pdf.stream(6, "/Filter /FlateDecode", "not flate data at all")
        }
        let all: [OptimizeOptions] = [
            OptimizeKit.off.with { $0.imageDpi = 8; $0.imageDpiAbove = 10 },
            OptimizeKit.off.with { $0.bilevelTolerance = 10 },
            OptimizeKit.off.with { $0.grayscale = true },
        ]
        for options in all {
            let source = try PdfDocument.open(file)
            let result = try PdfOptimizer(source).run(options)
            let after = try PdfDocument.open(result.bytes)
            XCTAssertEqual(after.name(try OptimizeKit.image(after).dictionary, "Filter"), "JBIG2Decode")
        }
    }

    func test_imageExtractionReadsTheGlobals() throws {
        let expected = try Jbig2Samples.withGlobalsPage()
        let data = try Jbig2Samples.withGlobals(), shared = try Jbig2Samples.globals()
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, self.image(64, 40, self.globalsEntry), data)
            pdf.stream(7, "", shared)
        }
        let found = try XCTUnwrap(try ImageExtractor.extract(document, [0]).first)
        XCTAssertFalse(found.image.isJpeg)
        let (w, h, rgba) = try ExportKit.pngDecode(found.image.data)
        XCTAssertEqual(w, 64)
        XCTAssertEqual(h, 40)
        var black = 0
        for y in 0..<h {
            for x in 0..<w {
                let isBlack = expected[y * 8 + x / 8] & UInt8(0x80 >> (x % 8)) == 0
                if isBlack { black += 1 }
                XCTAssertEqual(rgba[(y * w + x) * 4], isBlack ? 0 : 255)
            }
        }
        XCTAssertGreaterThan(black, 0)
    }

    func test_objectEditorExtractsAJbig2PictureAsPng() throws {
        let expected = try Jbig2Samples.withGlobalsPage()
        let data = try Jbig2Samples.withGlobals(), shared = try Jbig2Samples.globals()
        let session = try EditKit.session("q 100 0 0 60 100 600 cm /Im1 Do Q", more: { pdf in
            pdf.stream(8, self.image(64, 40, "/DecodeParms <</JBIG2Globals 9 0 R>>"), data)
            pdf.stream(9, "", shared)
        }, resources: "/XObject <</Im1 8 0 R>>")
        let editor = try PageEditor(session, 0, EditArialSource())
        let picture = try XCTUnwrap(editor.objects.compactMap { $0 as? ImageObject }.first)
        let png = try XCTUnwrap(try editor.extractImage(picture))
        XCTAssertEqual(png.fileExtension, "png")
        let (w, h, rgba) = try ExportKit.pngDecode(png.data)
        XCTAssertEqual(w, 64)
        XCTAssertEqual(h, 40)
        XCTAssertEqual(rgba[0], expected[0] & 0x80 == 0 ? 0 : 255)
    }

    func test_makeSmallerLeavesABilevelJbig2ImageAndItsGlobalsAlone() throws {
        let expected = try Jbig2Samples.withGlobalsPage()
        let data = try Jbig2Samples.withGlobals(), shared = try Jbig2Samples.globals()
        let file = OptimizeKit.build("q 10 0 0 10 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>") { pdf in
            pdf.stream(5, self.image(64, 40, "/DecodeParms <</JBIG2Globals 6 0 R>>"), data)
            pdf.stream(6, "", shared)
        }
        let document = try PdfDocument.open(file)
        let options = OptimizeKit.off.with { $0.imageDpi = 72; $0.imageDpiAbove = 100; $0.bilevelTolerance = 10 }
        let result = try PdfOptimizer(document).run(options)
        let after = try PdfDocument.open(result.bytes)
        let stream = try OptimizeKit.image(after)
        XCTAssertEqual(after.name(stream.dictionary, "Filter"), "JBIG2Decode")
        XCTAssertEqual(after.integer(stream.dictionary, "Width"), 64)
        XCTAssertEqual(try after.data(stream), expected)
        let parameters = try XCTUnwrap(after.resolve(stream.dictionary["DecodeParms"]) as? PdfDictionary)
        XCTAssertTrue(parameters["JBIG2Globals"] is PdfReference)
    }
}
