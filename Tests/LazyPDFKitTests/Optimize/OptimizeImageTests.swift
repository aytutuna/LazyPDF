import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeImageTests.cs: the same cases. The black and white picture is
// drawn with a generator of the test's own.

final class OptimizeImageTests: XCTestCase {
    private func dictionary(_ w: Int, _ h: Int, _ space: String, bpc: Int = 8, extra: String = "") -> String {
        "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace \(space) /BitsPerComponent \(bpc) /Filter /FlateDecode \(extra)"
    }

    private func downsample(_ dpi: Int, _ above: Int, quality: Int = 75) -> OptimizeOptions {
        OptimizeKit.off.with { $0.imageDpi = dpi; $0.imageDpiAbove = above; $0.jpegQuality = quality }
    }

    private func place(_ dictionary: String, _ samples: [UInt8], size: String = "100", more: ((TestPdf) -> Void)? = nil) -> [UInt8] {
        OptimizeKit.build("q \(size) 0 0 \(size) 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, dictionary, TestPdf.deflate(samples))
            more?(pdf)
        })
    }

    private func run(_ file: [UInt8], _ options: OptimizeOptions, codec: ImageCodec? = nil, name: String = "Im0") throws -> (image: PdfStream, after: PdfDocument) {
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document, codec).run(options)
        let after = try PdfDocument.open(result.bytes)
        return (try OptimizeKit.image(after, name), after)
    }

    func test_rgbImageIsAveragedDownToTheRequestedResolution() throws {
        let samples = OptimizeKit.gradient(200, 200, 3)
        let (image, after) = try run(place(dictionary(200, 200, "/DeviceRGB"), samples), downsample(72, 100))
        XCTAssertEqual(100, after.integer(image.dictionary, "Width"))
        XCTAssertEqual(100, after.integer(image.dictionary, "Height"))
        let data = try after.data(image)
        XCTAssertEqual(100 * 100 * 3, data.count)
        for c in 0..<3 {
            let expected = (Int(samples[c]) + Int(samples[3 + c]) + Int(samples[200 * 3 + c]) + Int(samples[200 * 3 + 3 + c]) + 2) / 4
            XCTAssertEqual(expected, Int(data[c]))
        }
    }

    func test_imageBelowTheThresholdIsLeft() throws {
        let samples = OptimizeKit.gradient(100, 100, 3)
        let (image, after) = try run(place(dictionary(100, 100, "/DeviceRGB"), samples), downsample(72, 150))
        XCTAssertEqual(100, after.integer(image.dictionary, "Width"))
    }

    func test_softMaskAndDecodeSurviveDownsampling() throws {
        let samples = OptimizeKit.gradient(200, 200, 3)
        let mask = OptimizeKit.gradient(200, 200, 1)
        let file = place(dictionary(200, 200, "/DeviceRGB", extra: "/Decode [1 0 1 0 1 0] /SMask 6 0 R"), samples, more: { pdf in
            pdf.stream(6, self.dictionary(200, 200, "/DeviceGray"), TestPdf.deflate(mask))
        })
        let (image, after) = try run(file, downsample(72, 100))
        XCTAssertEqual(100, after.integer(image.dictionary, "Width"))
        XCTAssertEqual(6, (after.resolve(image.dictionary["Decode"]) as? PdfArray)?.items.count)
        let soft = try XCTUnwrap(after.stream(image.dictionary, "SMask"))
        XCTAssertEqual(100, after.integer(soft.dictionary, "Width"))
        XCTAssertEqual(100 * 100, try after.data(soft).count)
    }

    func test_imageIsSizedForItsLargestUseInsideForms() throws {
        let samples = OptimizeKit.gradient(200, 200, 3)
        let file = OptimizeKit.build("q 0.5 0 0 0.5 0 0 cm /Fm0 Do Q q 1 0 0 1 100 100 cm /Fm0 Do Q", "/XObject <</Fm0 6 0 R>>", { pdf in
            pdf.stream(5, self.dictionary(200, 200, "/DeviceRGB"), TestPdf.deflate(samples))
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</XObject <</Im0 5 0 R>>>>", "q 100 0 0 100 0 0 cm /Im0 Do Q")
        })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(downsample(72, 100))
        let after = try PdfDocument.open(result.bytes)
        let form = try XCTUnwrap(after.resolve(after.dict(after.pages[0].resources, "XObject")?["Fm0"]) as? PdfStream)
        let image = try XCTUnwrap(after.resolve(after.dict(after.dict(form.dictionary, "Resources"), "XObject")?["Im0"]) as? PdfStream)
        // 288 dpi on the small copy and 144 on the big one: 100 pixels give the big one the 72 dpi asked for.
        XCTAssertEqual(100, after.integer(image.dictionary, "Width"))
    }

    func test_imageUsedAtFullSizeSomewhereIsLeft() throws {
        let samples = OptimizeKit.gradient(200, 200, 3)
        let file = OptimizeKit.build("q 50 0 0 50 0 0 cm /Im0 Do Q q 200 0 0 200 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, self.dictionary(200, 200, "/DeviceRGB"), TestPdf.deflate(samples))
        })
        let (image, after) = try run(file, downsample(72, 100))
        // 288 dpi at the small use but only 72 at the big one, which needs every pixel it has.
        XCTAssertEqual(200, after.integer(image.dictionary, "Width"))
    }

    func test_cmykKeepsFourComponents() throws {
        let samples = OptimizeKit.gradient(200, 200, 4)
        let (image, after) = try run(place(dictionary(200, 200, "/DeviceCMYK"), samples), downsample(72, 100))
        XCTAssertEqual("DeviceCMYK", after.name(image.dictionary, "ColorSpace"))
        XCTAssertEqual(100 * 100 * 4, try after.data(image).count)
    }

    func test_indexedImageBecomesRgb() throws {
        var palette = Array(repeating: UInt8(0), count: 256 * 3)
        for i in 0..<256 {
            palette[3 * i] = UInt8(i)
            palette[3 * i + 1] = UInt8(255 - i)
            palette[3 * i + 2] = 40
        }
        var indices = Array(repeating: UInt8(0), count: 200 * 200)
        for i in 0..<indices.count { indices[i] = UInt8(i % 200 * 255 / 200) }
        let space = "[/Indexed /DeviceRGB 255 <\(PdfGraph.hex(palette))>]"
        let (image, after) = try run(place(dictionary(200, 200, space), indices), downsample(72, 100))
        XCTAssertEqual("DeviceRGB", after.name(image.dictionary, "ColorSpace"))
        XCTAssertEqual(100 * 100 * 3, try after.data(image).count)
    }

    func test_blackAndWhitePictureBecomesOneBit() throws {
        let w = 40, h = 30
        let noise = OptimizeKit.noise(w * h, 3)
        var gray = Array(repeating: UInt8(0), count: w * h)
        for i in 0..<gray.count {
            gray[i] = (i / 5 + i / w) % 2 == 0 ? noise[i] % 4 : 252 + noise[i] % 4
        }
        let options = OptimizeKit.off.with { $0.bilevelTolerance = 8 }
        let (image, after) = try run(place(dictionary(w, h, "/DeviceGray"), gray), options)
        XCTAssertEqual(1, after.integer(image.dictionary, "BitsPerComponent"))
        let bits = try after.data(image)
        XCTAssertEqual(5 * h, bits.count)
        for y in 0..<h {
            for x in 0..<w {
                let white = (Int(bits[y * 5 + x / 8]) & (0x80 >> (x % 8))) != 0
                XCTAssertEqual(gray[y * w + x] > 128, white, "\(x),\(y)")
            }
        }
    }

    func test_pictureWithMidTonesStaysEightBit() throws {
        let gray = OptimizeKit.gradient(40, 30, 1)
        let (image, after) = try run(place(dictionary(40, 30, "/DeviceGray"), gray), OptimizeKit.off.with { $0.bilevelTolerance = 8 })
        XCTAssertEqual(8, after.integer(image.dictionary, "BitsPerComponent"))
    }

    func test_jpegIsDecodedShrunkAndWrittenAgain() throws {
        let dictionary = "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode"
        let file = OptimizeKit.build("q 72 0 0 72 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in pdf.stream(5, dictionary, OptimizeKit.tinyJpeg) })
        let codec = OptimizeFakeCodec()
        let (image, after) = try run(file, downsample(8, 10, quality: 60), codec: codec)
        XCTAssertEqual("DCTDecode", after.name(image.dictionary, "Filter"))
        XCTAssertEqual(8, after.integer(image.dictionary, "Width"))
        XCTAssertEqual(60, codec.lastQuality)
        XCTAssertTrue(after.rawData(image).count < OptimizeKit.tinyJpeg.count)
        XCTAssertEqual(8, codec.lastEncoded?.width)
    }

    func test_jpegWithoutACodecIsLeftAndSaysSo() throws {
        let dictionary = "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode"
        let file = OptimizeKit.build("q 72 0 0 72 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in pdf.stream(5, dictionary, OptimizeKit.tinyJpeg) })
        let document = try PdfDocument.open(file)
        let result = try PdfOptimizer(document).run(downsample(8, 10))
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual(16, after.integer(try OptimizeKit.image(after).dictionary, "Width"))
        XCTAssertTrue(result.notes.contains(OptimizeText.needsCodec))
    }

    func test_jpegWithADecodeArrayIsLeft() throws {
        let dictionary = "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Decode [1 0 1 0 1 0]"
        let file = OptimizeKit.build("q 72 0 0 72 10 10 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in pdf.stream(5, dictionary, OptimizeKit.tinyJpeg) })
        let codec = OptimizeFakeCodec()
        let (image, after) = try run(file, downsample(8, 10), codec: codec)
        XCTAssertEqual(16, after.integer(image.dictionary, "Width"))
        XCTAssertEqual(0, codec.decodes)
    }

    func test_imageOnlyReachedByAType3GlyphIsLeft() throws {
        let samples = OptimizeKit.gradient(200, 200, 3)
        let file = OptimizeKit.build("q 100 0 0 100 0 0 cm /Im0 Do Q BT /T3 10 Tf (a) Tj ET", "/XObject <</Im0 5 0 R>> /Font <</T3 6 0 R>>", { pdf in
            pdf.stream(5, self.dictionary(200, 200, "/DeviceRGB"), TestPdf.deflate(samples))
            pdf.obj(6, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] /CharProcs <</a 7 0 R>> /Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [1] /Resources <</XObject <</Im0 5 0 R>>>>>>")
            pdf.stream(7, "", "1 0 d0 q 1 0 0 1 0 0 cm /Im0 Do Q")
        })
        let (image, after) = try run(file, downsample(72, 100))
        XCTAssertEqual(200, after.integer(image.dictionary, "Width"))
    }
}
