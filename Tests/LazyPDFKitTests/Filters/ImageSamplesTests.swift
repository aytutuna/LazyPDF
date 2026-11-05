import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Filters/ImageSamplesTests.cs: the same cases.

final class ImageSamplesTests: XCTestCase {
    private func convert(_ dictionary: String, _ samples: [UInt8], _ streams: FilterFixtures.Streams? = nil, _ extra: ((PdfDictionary) -> Void)? = nil) throws -> PdfRgbaImage {
        let streams = streams ?? FilterFixtures.Streams()
        let image = try FilterFixtures.dict(dictionary)
        extra?(image)
        return try PdfImageSamples.toRgba(image, samples, FilterFixtures.resolve, streams.decode)
    }

    private func px(_ image: PdfRgbaImage, _ x: Int, _ y: Int) -> [UInt8] {
        let at = (y * image.width + x) * 4
        return Array(image.rgba[at..<at + 4])
    }

    private func near(_ expected: [UInt8], _ actual: [UInt8], _ tolerance: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }, "expected \(expected), got \(actual)", file: file, line: line)
    }

    private func colorSpace(_ items: PdfObject...) -> (PdfDictionary) -> Void {
        { $0["ColorSpace"] = PdfArray(items) }
    }

    func test_grayEightBit() throws {
        let image = try convert("<< /Width 2 /Height 2 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [0, 85, 170, 255])
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.rgba.count, 16)
        XCTAssertEqual(px(image, 0, 0), [0, 0, 0, 255])
        XCTAssertEqual(px(image, 1, 0), [85, 85, 85, 255])
        XCTAssertEqual(px(image, 0, 1), [170, 170, 170, 255])
        XCTAssertEqual(px(image, 1, 1), [255, 255, 255, 255])
    }

    func test_grayAtEveryDepth() throws {
        let cases: [(Int, [UInt8], [UInt8])] = [
            (1, [0b10100000], [255, 0, 255]),
            (2, [0b00_01_11_00], [0, 85, 255]),
            (4, [0x0F, 0x80], [0, 255, 136]),
            (16, [0, 0, 0xFF, 0xFF, 0x80, 0x00], [0, 255, 128]),
        ]
        for (bits, samples, expected) in cases {
            let image = try convert("<< /Width 3 /Height 1 /BitsPerComponent \(bits) /ColorSpace /DeviceGray >>", samples)
            XCTAssertEqual([px(image, 0, 0)[0], px(image, 1, 0)[0], px(image, 2, 0)[0]], expected, "\(bits) bits")
        }
    }

    func test_rowsStartOnByteBoundaries() throws {
        // Width 3 at 2 bits: six bits and two padding bits per row.
        let image = try convert("<< /Width 3 /Height 2 /BitsPerComponent 2 /ColorSpace /DeviceGray >>", [0b11_00_11_11, 0b00_11_00_00])
        XCTAssertEqual([px(image, 0, 0)[0], px(image, 1, 0)[0], px(image, 2, 0)[0]], [255, 0, 255])
        XCTAssertEqual([px(image, 0, 1)[0], px(image, 1, 1)[0], px(image, 2, 1)[0]], [0, 255, 0])
    }

    func test_decodeArrayInvertsGray() throws {
        let image = try convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Decode [1 0] >>", [0, 255])
        XCTAssertEqual(px(image, 0, 0)[0], 255)
        XCTAssertEqual(px(image, 1, 0)[0], 0)
    }

    func test_decodeArrayNarrowsTheRange() throws {
        let image = try convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Decode [0 0.5] >>", [0, 255])
        XCTAssertEqual(px(image, 0, 0)[0], 0)
        XCTAssertEqual(px(image, 1, 0)[0], 128)
    }

    func test_rgbAtEveryDepth() throws {
        for bits in [8, 16, 4] {
            let samples: [UInt8]
            switch bits {
            case 8: samples = [255, 0, 128, 0, 255, 0]
            case 16: samples = [0xFF, 0xFF, 0, 0, 0x80, 0, 0, 0, 0xFF, 0xFF, 0, 0]
            default: samples = [0xF0, 0x80, 0xF0]
            }
            let image = try convert("<< /Width 2 /Height 1 /BitsPerComponent \(bits) /ColorSpace /DeviceRGB >>", samples)
            near(bits == 4 ? [255, 0, 136, 255] : [255, 0, 128, 255], px(image, 0, 0))
            near([0, 255, 0, 255], px(image, 1, 0))
        }
    }

    func test_rgbWithDecodeSwapsRange() throws {
        let image = try convert("<< /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Decode [1 0 1 0 1 0] >>", [255, 0, 100])
        near([0, 255, 155, 255], px(image, 0, 0))
    }

    func test_cmykIsTheNaiveConversion() throws {
        let image = try convert("<< /Width 5 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceCMYK >>",
                                [0, 0, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0])
        XCTAssertEqual(px(image, 0, 0), [255, 255, 255, 255])
        XCTAssertEqual(px(image, 1, 0), [0, 0, 0, 255])
        XCTAssertEqual(px(image, 2, 0), [0, 255, 255, 255])
        XCTAssertEqual(px(image, 3, 0), [255, 0, 255, 255])
        XCTAssertEqual(px(image, 4, 0), [255, 255, 0, 255])
    }

    func test_indexedWithAStringLookup() throws {
        let image = try convert("<< /Width 4 /Height 1 /BitsPerComponent 8 /ColorSpace [/Indexed /DeviceRGB 2 <FF0000 00FF00 0000FF>] >>", [0, 1, 2, 9])
        XCTAssertEqual(px(image, 0, 0), [255, 0, 0, 255])
        XCTAssertEqual(px(image, 1, 0), [0, 255, 0, 255])
        XCTAssertEqual(px(image, 2, 0), [0, 0, 255, 255])
        XCTAssertEqual(px(image, 3, 0), [0, 0, 255, 255])
    }

    func test_indexedWithAStreamLookupAndPackedIndices() throws {
        let streams = FilterFixtures.Streams()
        let lookup = try streams.add("<< /Length 6 >>", [10, 20, 30, 200, 210, 220])
        let image = try convert("<< /Width 4 /Height 1 /BitsPerComponent 1 /ColorSpace [/Indexed /DeviceRGB 1 0] >>", [0b01100000], streams) {
            ($0["ColorSpace"] as? PdfArray)?.items[3] = lookup
        }
        XCTAssertEqual(px(image, 0, 0), [10, 20, 30, 255])
        XCTAssertEqual(px(image, 1, 0), [200, 210, 220, 255])
        XCTAssertEqual(px(image, 2, 0), [200, 210, 220, 255])
        XCTAssertEqual(px(image, 3, 0), [10, 20, 30, 255])
    }

    func test_indexedOverGrayAndShortLookup() throws {
        let image = try convert("<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace [/I /G 2 <00FF>] >>", [0, 1, 2])
        XCTAssertEqual(px(image, 0, 0)[0], 0)
        XCTAssertEqual(px(image, 1, 0)[0], 255)
        XCTAssertEqual(px(image, 2, 0)[0], 0)
    }

    func test_indexedOverIndexedIsDamaged() {
        assertProblem(.damaged, try convert("<< /Width 1 /Height 1 /ColorSpace [/Indexed [/Indexed /DeviceRGB 0 <000000>] 0 <00>] >>", [0]))
    }

    func test_iccBasedByComponentCount() throws {
        let cases: [(Int, [UInt8], Int)] = [(1, [200], 200), (3, [10, 20, 30], 10)]
        for (n, samples, firstChannel) in cases {
            let streams = FilterFixtures.Streams()
            let profile = try streams.add("<< /N \(n) >>", [])
            let image = try convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", samples, streams, colorSpace(PdfName("ICCBased"), profile))
            XCTAssertEqual(Int(px(image, 0, 0)[0]), firstChannel)
            XCTAssertEqual(Int(px(image, 0, 0)[1]), samples.count == 1 ? 200 : 20)
        }
    }

    func test_iccBasedWithFourComponentsIsCmyk() throws {
        let streams = FilterFixtures.Streams()
        let profile = try streams.add("<< /N 4 >>", [])
        let image = try convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [0, 0, 0, 255], streams, colorSpace(PdfName("ICCBased"), profile))
        XCTAssertEqual(px(image, 0, 0), [0, 0, 0, 255])
    }

    func test_iccBasedWithoutNFallsBackToTheAlternate() throws {
        let streams = FilterFixtures.Streams()
        let profile = try streams.add("<< /Alternate /DeviceRGB >>", [])
        let image = try convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [1, 2, 3], streams, colorSpace(PdfName("ICCBased"), profile))
        XCTAssertEqual(px(image, 0, 0), [1, 2, 3, 255])
    }

    func test_iccBasedWithNothingToGoByIsDamaged() throws {
        let streams = FilterFixtures.Streams()
        let profile = try streams.add("<< /N 7 >>", [])
        assertProblem(.damaged, try convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [1, 2, 3], streams, colorSpace(PdfName("ICCBased"), profile)))
    }

    func test_calGrayIsGray() throws {
        let image = try convert("<< /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace [/CalGray << /WhitePoint [0.95 1 1.09] /Gamma 2.2 >>] >>", [77])
        XCTAssertEqual(px(image, 0, 0), [77, 77, 77, 255])
    }

    func test_calRgbWithTheSrgbMatrixStaysCloseToTheInput() throws {
        let space = "[/CalRGB << /WhitePoint [0.9505 1 1.089] /Gamma [2.2 2.2 2.2] " +
            "/Matrix [0.4124 0.2126 0.0193 0.3576 0.7152 0.1192 0.1805 0.0722 0.9505] >>]"
        let image = try convert("<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace \(space) >>", [255, 255, 255, 0, 0, 0, 128, 128, 128])
        near([255, 255, 255, 255], px(image, 0, 0), 2)
        near([0, 0, 0, 255], px(image, 1, 0), 1)
        near([128, 128, 128, 255], px(image, 2, 0), 4)
    }

    func test_labMapsLightnessToGray() throws {
        let space = "[/Lab << /WhitePoint [0.9642 1 0.8249] /Range [-128 127 -128 127] >>]"
        let image = try convert("<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace \(space) >>", [255, 128, 128, 0, 128, 128, 128, 128, 128])
        XCTAssertTrue(px(image, 0, 0).prefix(3).allSatisfy { $0 >= 245 })
        XCTAssertTrue(px(image, 1, 0).prefix(3).allSatisfy { $0 <= 8 })
        let middle = px(image, 2, 0).map { Int($0) }
        XCTAssertTrue((105...135).contains(middle[0]))
        XCTAssertTrue((0...8).contains(abs(middle[0] - middle[1])))
        XCTAssertTrue((0...8).contains(abs(middle[1] - middle[2])))
    }

    func test_labAxesTurnTheColour() throws {
        let space = "[/Lab << /WhitePoint [0.9642 1 0.8249] /Range [-100 100 -100 100] >>]"
        // L 50 with a = +100 is red-ish, a = -100 green-ish, b = +100 yellow, b = -100 blue.
        let image = try convert("<< /Width 4 /Height 1 /BitsPerComponent 8 /ColorSpace \(space) >>",
                                [128, 255, 128, 128, 0, 128, 128, 128, 255, 128, 128, 0])
        let red = px(image, 0, 0).map { Int($0) }
        let green = px(image, 1, 0).map { Int($0) }
        let yellow = px(image, 2, 0).map { Int($0) }
        let blue = px(image, 3, 0).map { Int($0) }
        XCTAssertTrue(red[0] > red[1] + 60)
        XCTAssertTrue(green[1] > green[0] + 60)
        XCTAssertTrue(yellow[0] > yellow[2] + 60)
        XCTAssertTrue(blue[2] > blue[0] + 60)
    }

    func test_separationThroughAnExponentialTint() throws {
        let image = try convert("<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace [/Separation /Spot /DeviceGray << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>] >>", [0, 128, 255])
        XCTAssertEqual(px(image, 0, 0)[0], 255)
        near([127, 127, 127, 255], px(image, 1, 0), 1)
        XCTAssertEqual(px(image, 2, 0)[0], 0)
    }

    func test_separationThroughACalculatorIntoCmyk() throws {
        let streams = FilterFixtures.Streams()
        let tint = try streams.add("<< /FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1 0 1] >>", Array("{ 0 exch 0 0 }".utf8))
        let image = try convert("<< /Width 2 /Height 1 /BitsPerComponent 8 >>", [0, 255], streams,
                                colorSpace(PdfName("Separation"), PdfName("Magenta"), PdfName("DeviceCMYK"), tint))
        XCTAssertEqual(px(image, 0, 0), [255, 255, 255, 255])
        XCTAssertEqual(px(image, 1, 0), [255, 0, 255, 255])
    }

    func test_separationThroughASampledTint() throws {
        let streams = FilterFixtures.Streams()
        let tint = try streams.add("<< /FunctionType 0 /Domain [0 1] /Range [0 1] /Size [2] /BitsPerSample 8 >>", [255, 0])
        let image = try convert("<< /Width 2 /Height 1 /BitsPerComponent 8 >>", [0, 255], streams,
                                colorSpace(PdfName("Separation"), PdfName("Black"), PdfName("DeviceGray"), tint))
        XCTAssertEqual(px(image, 0, 0)[0], 255)
        XCTAssertEqual(px(image, 1, 0)[0], 0)
    }

    func test_deviceNWithTwoColorantsThroughACalculator() throws {
        let streams = FilterFixtures.Streams()
        let tint = try streams.add("<< /FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1] >>", Array("{ 1 exch sub exch 1 exch sub exch 1 }".utf8))
        let image = try convert("<< /Width 3 /Height 1 /BitsPerComponent 8 >>", [255, 0, 0, 255, 0, 0], streams,
                                colorSpace(PdfName("DeviceN"), try FilterFixtures.parse("[/Cyan /Spot]"), PdfName("DeviceRGB"), tint))
        XCTAssertEqual(px(image, 0, 0), [0, 255, 255, 255])
        XCTAssertEqual(px(image, 1, 0), [255, 0, 255, 255])
        XCTAssertEqual(px(image, 2, 0), [255, 255, 255, 255])
    }

    func test_deviceNTintFunctionWithTheWrongInputCountIsDamaged() throws {
        let streams = FilterFixtures.Streams()
        let tint = try streams.add("<< /FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1] >>", Array("{ dup dup }".utf8))
        let space = colorSpace(PdfName("DeviceN"), try FilterFixtures.parse("[/A /B]"), PdfName("DeviceRGB"), tint)
        assertProblem(.damaged, try convert("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [1, 2], streams, space))
    }

    func test_imageMaskPaintsWhereTheSampleIsZero() throws {
        let image = try convert("<< /Width 4 /Height 1 /ImageMask true >>", [0b01010000])
        XCTAssertEqual(px(image, 0, 0), [0, 0, 0, 255])
        XCTAssertEqual(px(image, 1, 0)[3], 0)
        XCTAssertEqual(px(image, 2, 0)[3], 255)
        XCTAssertEqual(px(image, 3, 0)[3], 0)
    }

    func test_imageMaskDecodeInverts() throws {
        let image = try convert("<< /Width 2 /Height 1 /ImageMask true /Decode [1 0] >>", [0b01000000])
        XCTAssertEqual(px(image, 0, 0)[3], 0)
        XCTAssertEqual(px(image, 1, 0)[3], 255)
    }

    func test_colorKeyMaskAlphaValues() throws {
        let image = try convert("<< /Width 4 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Mask [10 20] >>", [9, 10, 20, 21])
        XCTAssertEqual((0..<4).map { Int(px(image, $0, 0)[3]) }, [255, 0, 0, 255])
    }

    func test_colorKeyMaskOnIndexedUsesTheIndices() throws {
        let image = try convert("<< /Width 3 /Height 1 /BitsPerComponent 8 /ColorSpace [/Indexed /DeviceRGB 2 <FF0000 00FF00 0000FF>] /Mask [1 1] >>", [0, 1, 2])
        XCTAssertEqual((0..<3).map { Int(px(image, $0, 0)[3]) }, [255, 0, 255])
    }

    func test_colorKeyMaskNeedsOneRangePerComponent() throws {
        let image = try convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Mask [0 255] >>", [1, 2, 3, 4, 5, 6])
        XCTAssertEqual([px(image, 0, 0)[3], px(image, 1, 0)[3]], [255, 255])
    }

    func test_softMaskSetsAlpha() throws {
        let streams = FilterFixtures.Streams()
        let mask = try streams.add("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [0, 200])
        let image = try convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [50, 60], streams) { $0["SMask"] = mask }
        XCTAssertEqual(px(image, 0, 0), [50, 50, 50, 0])
        XCTAssertEqual(px(image, 1, 0), [60, 60, 60, 200])
    }

    func test_softMaskOfAnotherSizeIsSampledNearest() throws {
        let streams = FilterFixtures.Streams()
        let mask = try streams.add("<< /Width 2 /Height 2 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [10, 20, 30, 40])
        let image = try convert("<< /Width 4 /Height 4 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [UInt8](repeating: 0, count: 16), streams) { $0["SMask"] = mask }
        XCTAssertEqual(px(image, 1, 1)[3], 10)
        XCTAssertEqual(px(image, 2, 1)[3], 20)
        XCTAssertEqual(px(image, 1, 2)[3], 30)
        XCTAssertEqual(px(image, 3, 3)[3], 40)
    }

    func test_softMaskDecodeAndDepth() throws {
        let streams = FilterFixtures.Streams()
        let mask = try streams.add("<< /Width 2 /Height 1 /BitsPerComponent 1 /ColorSpace /DeviceGray /Decode [1 0] >>", [0b01000000])
        let image = try convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [1, 2], streams) { $0["SMask"] = mask }
        XCTAssertEqual(px(image, 0, 0)[3], 255)
        XCTAssertEqual(px(image, 1, 0)[3], 0)
    }

    func test_softMaskWinsOverMask() throws {
        let streams = FilterFixtures.Streams()
        let soft = try streams.add("<< /Width 1 /Height 1 /BitsPerComponent 8 >>", [99])
        let hard = try streams.add("<< /Width 1 /Height 1 /ImageMask true >>", [0x80])
        let image = try convert("<< /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [1], streams) {
            $0["SMask"] = soft
            $0["Mask"] = hard
        }
        XCTAssertEqual(px(image, 0, 0)[3], 99)
    }

    func test_stencilMaskHidesWhereTheSampleIsOne() throws {
        let streams = FilterFixtures.Streams()
        let mask = try streams.add("<< /Width 4 /Height 1 /ImageMask true /BitsPerComponent 1 >>", [0b01100000])
        let image = try convert("<< /Width 4 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [10, 20, 30, 40], streams) { $0["Mask"] = mask }
        XCTAssertEqual((0..<4).map { Int(px(image, $0, 0)[3]) }, [255, 0, 0, 255])
    }

    func test_stencilMaskOfAnotherSizeIsSampledNearest() throws {
        let streams = FilterFixtures.Streams()
        let mask = try streams.add("<< /Width 8 /Height 1 /ImageMask true >>", [0b00001111])
        let image = try convert("<< /Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [10, 20], streams) { $0["Mask"] = mask }
        XCTAssertEqual(px(image, 0, 0)[3], 255)
        XCTAssertEqual(px(image, 1, 0)[3], 0)
    }

    func test_missingSamplesReadAsZero() throws {
        let image = try convert("<< /Width 2 /Height 3 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", [200, 100, 50])
        XCTAssertEqual(px(image, 0, 1)[0], 50)
        XCTAssertEqual(px(image, 1, 1)[0], 0)
        XCTAssertEqual(px(image, 0, 2)[0], 0)
        XCTAssertEqual(px(image, 1, 2)[3], 255)
    }

    func test_missingColorSpaceIsGuessedFromTheSampleCount() throws {
        let dictionary = "<< /Width 1 /Height 1 /BitsPerComponent 8 >>"
        XCTAssertEqual(px(try convert(dictionary, [1, 2, 3]), 0, 0), [1, 2, 3, 255])
        XCTAssertEqual(px(try convert(dictionary, [9]), 0, 0), [9, 9, 9, 255])
        XCTAssertEqual(px(try convert(dictionary, [0, 0, 0, 255]), 0, 0), [0, 0, 0, 255])
        assertProblem(.damaged, try convert(dictionary, [1, 2]))
    }

    func test_inlineImageKeysAreRead() throws {
        let image = try convert("<< /W 2 /H 1 /BPC 8 /CS /G >>", [10, 20])
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(px(image, 0, 0)[0], 10)
        let mask = try convert("<< /W 8 /H 1 /IM true /D [1 0] >>", [0x0F])
        XCTAssertEqual(px(mask, 0, 0)[3], 0)
        XCTAssertEqual(px(mask, 7, 0)[3], 255)
    }

    func test_badImagesAreRefusedBeforeAnyAllocation() {
        let cases: [(String, PdfReadProblem)] = [
            ("<< /Width 0 /Height 1 /ColorSpace /DeviceGray >>", .damaged),
            ("<< /Width 1 /Height -4 /ColorSpace /DeviceGray >>", .damaged),
            ("<< /Height 1 /ColorSpace /DeviceGray >>", .damaged),
            ("<< /Width 1 /Height 1 /BitsPerComponent 3 /ColorSpace /DeviceGray >>", .damaged),
            ("<< /Width 100000 /Height 100000 /BitsPerComponent 8 /ColorSpace /DeviceGray >>", .unsupported),
            ("<< /Width 2000000000 /Height 2000000000 /ColorSpace /DeviceRGB >>", .unsupported),
            ("<< /Width 1 /Height 1 /ColorSpace [/Pattern] >>", .unsupported),
            ("<< /Width 1 /Height 1 /ColorSpace /Cs7 >>", .unsupported),
            ("<< /Width 1 /Height 1 /ColorSpace 12 >>", .damaged),
            ("<< /Width 1 /Height 1 /ColorSpace [/Indexed /DeviceRGB 1] >>", .damaged),
            ("<< /Width 1 /Height 1 /ColorSpace [/Separation /X /DeviceGray] >>", .damaged),
        ]
        for (dictionary, problem) in cases {
            assertProblem(problem, try convert(dictionary, [0]))
        }
    }

    func test_aRowTooWideForTheLimitIsUnsupported() {
        assertProblem(.unsupported, try convert("<< /Width 134000000 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB >>", []))
    }

    func test_bigImageConvertsInReasonableTime() throws {
        let samples = FilterFixtures.randomBytes(2000 * 2000 * 3)
        let start = Date()
        let image = try convert("<< /Width 2000 /Height 2000 /BitsPerComponent 8 /ColorSpace /DeviceRGB >>", samples)
        XCTAssertEqual(image.rgba.count, 2000 * 2000 * 4)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
