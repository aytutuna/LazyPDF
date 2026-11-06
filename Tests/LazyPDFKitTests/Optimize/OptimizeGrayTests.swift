import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeGrayTests.cs: the same cases. PdfPigStillReadsTheTextOfAGrayFile is
// PdfPig alone in the C#; its twin reads the text with the engine.

final class OptimizeGrayTests: XCTestCase {
    private final class Fills: ContentVisitor {
        var colors: [(fill: RgbColor, stroke: RgbColor)] = []

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            colors.append((context.state.fillColor.rgb, context.state.strokeColor.rgb))
        }
    }

    private func painted(_ file: [UInt8]) throws -> [(fill: RgbColor, stroke: RgbColor)] {
        let document = try PdfDocument.open(file)
        let fills = Fills()
        ContentInterpreter(document).run(document.pages[0], fills)
        return fills.colors
    }

    private let gray = OptimizeKit.off.with { $0.grayscale = true }

    private func luminance(_ c: RgbColor) -> Int {
        Int((0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)).rounded(.toNearestOrEven))
    }

    private func run(_ file: [UInt8], _ codec: ImageCodec? = nil) throws -> OptimizeResult {
        let document = try PdfDocument.open(file)
        return try PdfOptimizer(document, codec).run(gray)
    }

    func test_colourOperatorsBecomeGrayWithTheSameBrightness() throws {
        let content = "1 0 0 rg 0 0 50 50 re f 0 0 1 RG 0.2 0.4 0.6 0.1 k 0 0 20 20 re B /Cs0 cs 0.5 0.25 0.75 sc 0 0 9 9 re f /DeviceCMYK cs 0.1 0.2 0.3 0.4 sc 0 0 5 5 re f"
        let file = OptimizeKit.build(content, "/ColorSpace <</Cs0 [/ICCBased 5 0 R]>>", { pdf in pdf.stream(5, "/N 3", "profile") })
        let before = try painted(file)
        let result = try run(file)
        let after = try painted(result.bytes)
        XCTAssertEqual(before.count, after.count)
        for i in 0..<before.count {
            XCTAssertTrue(abs(Int(after[i].fill.r) - luminance(before[i].fill)) <= 1, "fill \(i)")
            XCTAssertEqual(after[i].fill.r, after[i].fill.g)
            XCTAssertEqual(after[i].fill.g, after[i].fill.b)
            XCTAssertTrue(abs(Int(after[i].stroke.r) - luminance(before[i].stroke)) <= 1, "stroke \(i)")
            XCTAssertEqual(after[i].stroke.r, after[i].stroke.b)
        }
        let document = try PdfDocument.open(result.bytes)
        let operators = ContentParser.parse(document.pages[0].contents()).map { $0.operator }
        XCTAssertFalse(operators.contains("rg"))
        XCTAssertFalse(operators.contains("RG"))
        XCTAssertFalse(operators.contains("k"))
    }

    func test_operatorsInAFormFollowTheNumberOfOperands() throws {
        let file = OptimizeKit.build("q 1 0 0 rg /Fm0 Do Q", "/XObject <</Fm0 5 0 R>>", { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "0 1 0 sc 0 0 10 10 re f 0 0 0 1 k 0 0 5 5 re f")
        })
        let result = try run(file)
        let document = try PdfDocument.open(result.bytes)
        let form = try XCTUnwrap(document.resolve(document.dict(document.pages[0].resources, "XObject")?["Fm0"]) as? PdfStream)
        let operations = ContentParser.parse(try document.data(form))
        for o in operations where o.operator == "sc" || o.operator == "g" { XCTAssertEqual(1, o.operands.count) }
        XCTAssertTrue(operations.contains { $0.operator == "g" && abs(($0.number(0) ?? 0) - 0.587) < 0.001 })
        XCTAssertEqual(2, result.steps.first { $0.kind == .grayscale }?.count)
    }

    func test_shadingsAndSpotColoursAreLeftAndReported() throws {
        let resources = "/Shading <</Sh0 << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1>>>>>> " +
            "/ColorSpace <</Sp0 [/Separation /Spot /DeviceRGB <</FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 0 0] /N 1>>]>>"
        let file = OptimizeKit.build("/Sh0 sh /Sp0 cs 1 scn 0 0 10 10 re f", resources)
        let result = try run(file)
        XCTAssertTrue(result.notes.contains(OptimizeText.leftColor))
        let document = try PdfDocument.open(result.bytes)
        let operations = ContentParser.parse(document.pages[0].contents())
        let operators = operations.map { $0.operator }
        XCTAssertTrue(operators.contains("sh"))
        XCTAssertTrue(operators.contains("scn"))
        XCTAssertEqual("Sp0", (operations.first { $0.operator == "cs" }?.operands.first as? PdfName)?.value)
    }

    func test_imagesAreConvertedAndKeepTheirMask() throws {
        let w = 8, h = 8
        let rgb = OptimizeKit.gradient(w, h, 3)
        let dictionary = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /BitsPerComponent 8 /Filter /FlateDecode"
        let file = OptimizeKit.build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, dictionary + " /ColorSpace /DeviceRGB /SMask 6 0 R", TestPdf.deflate(rgb))
            pdf.stream(6, dictionary + " /ColorSpace /DeviceGray", TestPdf.deflate(OptimizeKit.gradient(w, h, 1)))
        })
        let result = try run(file)
        let after = try PdfDocument.open(result.bytes)
        let image = try OptimizeKit.image(after)
        XCTAssertEqual("DeviceGray", after.name(image.dictionary, "ColorSpace"))
        XCTAssertNotNil(after.stream(image.dictionary, "SMask"))
        let gray = try after.data(image)
        XCTAssertEqual(w * h, gray.count)
        for i in 0..<gray.count {
            XCTAssertEqual(ImageKit.luminance(Int(rgb[3 * i]), Int(rgb[3 * i + 1]), Int(rgb[3 * i + 2])), gray[i])
        }
    }

    func test_jpegBecomesGrayThroughTheCodec() throws {
        let file = OptimizeKit.build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", OptimizeKit.tinyJpeg)
        })
        let codec = OptimizeFakeCodec()
        let result = try run(file, codec)
        let written = try XCTUnwrap(codec.lastEncoded)
        for i in 0..<(written.width * written.height) { XCTAssertEqual(written.rgba[4 * i], written.rgba[4 * i + 1]) }
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual("DCTDecode", after.name(try OptimizeKit.image(after).dictionary, "Filter"))
        XCTAssertFalse(result.notes.contains(OptimizeText.needsCodec))
    }

    func test_jpegWithoutACodecStaysInColourAndSaysSo() throws {
        let file = OptimizeKit.build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", OptimizeKit.tinyJpeg)
        })
        let result = try run(file)
        let after = try PdfDocument.open(result.bytes)
        XCTAssertEqual("DeviceRGB", after.name(try OptimizeKit.image(after).dictionary, "ColorSpace"))
        XCTAssertTrue(result.notes.contains(OptimizeText.needsCodec))
        XCTAssertTrue(result.notes.contains(OptimizeText.leftColor))
    }

    func test_pdfPigStillReadsTheTextOfAGrayFile() throws {
        let file = OptimizeKit.build("1 0 0 rg BT /F1 12 Tf 10 100 Td (red words) Tj ET", "/Font <</F1 5 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        })
        let result = try run(file)
        XCTAssertEqual("red words", try OptimizeKit.engineText(result.bytes).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func operators(_ document: PdfDocument, _ stream: PdfStream) throws -> [ContentOperation] {
        ContentParser.parse(try document.data(stream))
    }

    func test_anIndexedImagesMatteIsLookedUpInThePalette() throws {
        let dictionary = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /BitsPerComponent 8 /Filter /FlateDecode"
        let file = OptimizeKit.build("q 80 0 0 80 0 0 cm /Im0 Do Q", "/XObject <</Im0 5 0 R>>", { pdf in
            pdf.stream(5, dictionary + " /ColorSpace [/Indexed /DeviceRGB 1 <FFFFFF000000>] /SMask 6 0 R", TestPdf.deflate(Array(repeating: 0, count: 64)))
            pdf.stream(6, dictionary + " /ColorSpace /DeviceGray /Matte [1]", TestPdf.deflate(OptimizeKit.gradient(8, 8, 1)))
        })
        let after = try PdfDocument.open(try run(file).bytes)
        let soft = try XCTUnwrap(after.stream(try OptimizeKit.image(after).dictionary, "SMask"))
        let matte = try XCTUnwrap(after.array(soft.dictionary, "Matte"))
        XCTAssertEqual(1, matte.items.count)
        XCTAssertEqual(0, (matte.items[0] as? PdfNumber)?.value)
    }

    func test_colourInASpaceThatCannotBeLookedUpStaysAndIsReported() throws {
        let file = OptimizeKit.build("/Fm0 Do", "/XObject <</Fm0 5 0 R>>", { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "/Cs1 cs 1 0 0 sc 0 0 5 5 re f")
        })
        let result = try run(file)
        XCTAssertTrue(result.notes.contains(OptimizeText.leftColor))
    }

    func test_aColourSpaceNamedInOneStreamAndSetInTheNextIsLeftAlone() throws {
        let file = OptimizeKit.build("/DeviceRGB cs 1 0 0", "", { pdf in pdf.stream(5, "", "sc 0 0 5 5 re f") }, contents: "[4 0 R 5 0 R]")
        let result = try run(file)
        let document = try PdfDocument.open(result.bytes)
        let all = ContentParser.parse(document.pages[0].contents())
        XCTAssertEqual("DeviceRGB", (all.filter { $0.operator == "cs" }.first?.operands.first as? PdfName)?.value)
        XCTAssertEqual(3, all.filter { $0.operator == "sc" }.first?.operands.count)
        XCTAssertTrue(result.notes.contains(OptimizeText.leftColor))
    }

    func test_aFormInheritingALabSpaceKeepsItsOperands() throws {
        let file = OptimizeKit.build("/L cs /Fm0 Do", "/ColorSpace <</L [/Lab <</WhitePoint [0.95 1 1.09]>>]>> /XObject <</Fm0 5 0 R>>", { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "50 20 30 sc 0 0 5 5 re f")
        })
        let result = try run(file)
        let document = try PdfDocument.open(result.bytes)
        let form = try XCTUnwrap(document.resolve(document.dict(document.pages[0].resources, "XObject")?["Fm0"]) as? PdfStream)
        XCTAssertEqual(3, try operators(document, form).filter { $0.operator == "sc" }.first?.operands.count)
    }

    func test_everyInheritedColourInAFormIsConverted() throws {
        let file = OptimizeKit.build("/Fm0 Do", "/XObject <</Fm0 5 0 R>>", { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "1 0 0 sc 0 0 5 5 re f 0 1 0 sc 5 5 5 5 re f")
        })
        let result = try run(file)
        let document = try PdfDocument.open(result.bytes)
        let form = try XCTUnwrap(document.resolve(document.dict(document.pages[0].resources, "XObject")?["Fm0"]) as? PdfStream)
        let set = try operators(document, form).filter { $0.operator == "sc" || $0.operator == "g" }
        XCTAssertEqual(2, set.count)
        for o in set { XCTAssertEqual(1, o.operands.count) }
    }

    func test_anRgbCallerAndALabSomewhereElseStillAgreeWithTheForm() throws {
        let resources = "/ColorSpace <</Cs0 [/ICCBased 6 0 R] /L [/Lab <</WhitePoint [0.95 1 1.09]>>]>> /XObject <</Fm0 5 0 R>>"
        let file = OptimizeKit.build("/Cs0 cs /Fm0 Do", resources, { pdf in
            pdf.stream(5, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "0.2 0.4 0.6 sc 0 0 5 5 re f")
            pdf.stream(6, "/N 3", "profile")
        })
        let result = try run(file)
        let document = try PdfDocument.open(result.bytes)
        let form = try XCTUnwrap(document.resolve(document.dict(document.pages[0].resources, "XObject")?["Fm0"]) as? PdfStream)
        let pageOps = ContentParser.parse(document.pages[0].contents()).filter { $0.operator == "cs" }
        XCTAssertEqual("DeviceGray", (pageOps.first?.operands.first as? PdfName)?.value)
        let set = try operators(document, form).filter { $0.operator == "sc" || $0.operator == "g" }
        XCTAssertEqual(1, set.count)
        XCTAssertEqual(1, set.first?.operands.count)
    }
}
