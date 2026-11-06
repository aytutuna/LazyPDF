import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/OptimizeGrayCallerTests.cs: the same cases.

final class OptimizeGrayCallerTests: XCTestCase {
    private let lab = "/L [/Lab <</WhitePoint [0.95 1 1.09]>>]"
    private let rgb = "/Cs0 [/ICCBased 6 0 R]"
    private let formEntries = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]"
    private let gray = OptimizeKit.off.with { $0.grayscale = true }

    private func run(_ file: [UInt8]) throws -> [UInt8] {
        let document = try PdfDocument.open(file)
        return try PdfOptimizer(document).run(gray).bytes
    }

    private func page(_ file: [UInt8], _ index: Int = 0) throws -> [ContentOperation] {
        let document = try PdfDocument.open(file)
        return ContentParser.parse(document.pages[index].contents())
    }

    // The form reached from the first page by these names, each looked up in the resources of the one before.
    private func form(_ file: [UInt8], _ path: String...) throws -> [ContentOperation] {
        let document = try PdfDocument.open(file)
        var resources = document.pages[0].resources
        var form: PdfStream?
        for name in path {
            form = try XCTUnwrap(document.resolve(document.dict(resources, "XObject")?[name]) as? PdfStream)
            resources = document.dict(form?.dictionary, "Resources")
        }
        return ContentParser.parse(try document.data(try XCTUnwrap(form)))
    }

    private func spaceName(_ operations: [ContentOperation], _ op: String) -> String? {
        (operations.first { $0.operator == op }?.operands.first as? PdfName)?.value
    }

    private func single(_ operations: [ContentOperation], _ ops: String...) throws -> ContentOperation {
        let found = operations.filter { ops.contains($0.operator) }
        XCTAssertEqual(1, found.count)
        return try XCTUnwrap(found.first)
    }

    private func pages(_ contentsA: String, _ contentsB: String, _ resourcesA: String, _ resourcesB: String, _ more: (TestPdf) -> Void) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents \(contentsA) /Resources \(resourcesA)>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents \(contentsB) /Resources \(resourcesB)>>")
        more(pdf)
        return pdf.finish()
    }

    func test_aSpotStrokeDoesNotKeepTheFillOperandsOfAForm() throws {
        let resources = "/ColorSpace <</Sp [/Separation /Spot /DeviceRGB <</FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 0 0] /N 1>>] " + rgb + ">> /XObject <</Fm0 5 0 R>>"
        let file = try run(OptimizeKit.build("/Sp CS 1 SCN /Cs0 cs 1 0 0 sc /Fm0 Do", resources, { pdf in
            pdf.stream(5, self.formEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f")
            pdf.stream(6, "/N 3", "profile")
        }))
        XCTAssertEqual("DeviceGray", spaceName(try page(file), "cs"))
        XCTAssertEqual(1, try single(try form(file, "Fm0"), "sc", "g").operands.count)
    }

    func test_aLabStrokeKeepsOnlyTheStrokeOperandsOfAForm() throws {
        let file = try run(OptimizeKit.build("/L CS /Cs0 cs /Fm0 Do", "/ColorSpace <<" + lab + " " + rgb + ">> /XObject <</Fm0 5 0 R>>", { pdf in
            pdf.stream(5, self.formEntries, "0.2 0.4 0.6 sc 0.2 0.4 0.6 SC 0 0 5 5 re B")
            pdf.stream(6, "/N 3", "profile")
        }))
        let form = try self.form(file, "Fm0")
        XCTAssertEqual("L", spaceName(try page(file), "CS"))
        XCTAssertEqual(1, try single(form, "sc", "g").operands.count)
        XCTAssertEqual(3, try single(form, "SC").operands.count)
    }

    func test_anRgbOperatorSetsTheSpaceTheColoursAfterItAreWrittenFor() throws {
        let file = try run(OptimizeKit.build("1 0 0 rg 0 0 5 5 re f 0 1 0 sc 5 5 5 5 re f", "/ColorSpace <<" + lab + ">>"))
        let operations = try page(file)
        XCTAssertFalse(operations.contains { $0.operator == "rg" })
        for o in operations where o.operator == "g" || o.operator == "sc" { XCTAssertEqual(1, o.operands.count) }
    }

    func test_aFormPaintedAfterAnRgbOperatorFollowsItWhateverTheFileHolds() throws {
        let file = try run(OptimizeKit.build("1 0 0 rg /Fm0 Do", "/ColorSpace <<" + lab + ">> /XObject <</Fm0 5 0 R>>", { pdf in
            pdf.stream(5, self.formEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f")
        }))
        XCTAssertTrue(try page(file).contains { $0.operator == "g" })
        XCTAssertEqual(1, try single(try form(file, "Fm0"), "sc", "g").operands.count)
    }

    func test_aFormCalledFromAFormGetsTheSpaceOfThePage() throws {
        let file = try run(OptimizeKit.build("/Cs0 cs /Fm0 Do", "/ColorSpace <<" + lab + " " + rgb + ">> /XObject <</Fm0 5 0 R>>", { pdf in
            pdf.stream(5, self.formEntries + " /Resources <</XObject <</Fm1 7 0 R>>>>", "/Fm1 Do")
            pdf.stream(6, "/N 3", "profile")
            pdf.stream(7, self.formEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f")
        }))
        XCTAssertEqual("DeviceGray", spaceName(try page(file), "cs"))
        XCTAssertEqual(1, try single(try form(file, "Fm0", "Fm1"), "sc", "g").operands.count)
    }

    func test_aFormThatSetsItsOwnSpaceTellsTheFormItCallsWhateverTheObjectOrder() throws {
        let file = try run(OptimizeKit.build("/Fm0 Do", "/ColorSpace <<" + lab + ">> /XObject <</Fm0 7 0 R>>", { pdf in
            pdf.stream(5, self.formEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f")
            pdf.stream(6, "/N 3", "profile")
            pdf.stream(7, self.formEntries + " /Resources <</ColorSpace <</Cs1 [/ICCBased 6 0 R]>> /XObject <</Fm1 5 0 R>>>>", "/Cs1 cs /Fm1 Do")
        }))
        XCTAssertEqual("DeviceGray", spaceName(try form(file, "Fm0"), "cs"))
        XCTAssertEqual(1, try single(try form(file, "Fm0", "Fm1"), "sc", "g").operands.count)
    }

    func test_aFormPaintedUnderLabAndRgbKeepsItsOperandsAndSoDoesTheRgbCs() throws {
        let resources = "<</ColorSpace <<" + lab + " " + rgb + ">> /XObject <</Fm0 5 0 R>>>>"
        let file = try run(pages("20 0 R", "21 0 R", resources, resources, { pdf in
            pdf.stream(5, self.formEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f")
            pdf.stream(6, "/N 3", "profile")
            pdf.stream(20, "", "/L cs /Fm0 Do")
            pdf.stream(21, "", "/Cs0 cs /Fm0 Do")
        }))
        XCTAssertEqual("L", spaceName(try page(file, 0), "cs"))
        XCTAssertEqual("Cs0", spaceName(try page(file, 1), "cs"))
        XCTAssertEqual(3, try single(try form(file, "Fm0"), "sc").operands.count)
    }

    func test_aLabCallerReachedThroughAFormHoldsBackAnotherPagesRgbCs() throws {
        let resources = "<</ColorSpace <<" + lab + " " + rgb + ">> /XObject <</Fm0 5 0 R>>>>"
        let file = try run(pages("20 0 R", "21 0 R", resources, resources, { pdf in
            pdf.stream(5, self.formEntries + " /Resources <</XObject <</Fm1 7 0 R>>>>", "/Fm1 Do")
            pdf.stream(6, "/N 3", "profile")
            pdf.stream(7, self.formEntries, "0.2 0.4 0.6 sc 0 0 5 5 re f")
            pdf.stream(20, "", "/L cs /Fm0 Do")
            pdf.stream(21, "", "/Cs0 cs /Fm0 Do")
        }))
        XCTAssertEqual("Cs0", spaceName(try page(file, 1), "cs"))
        XCTAssertEqual(3, try single(try form(file, "Fm0", "Fm1"), "sc").operands.count)
    }

    func test_aStreamSharedByPagesIsReadInEachPagesState() throws {
        let file = try run(pages("[20 0 R 21 0 R]", "[20 0 R 22 0 R]", "12 0 R", "12 0 R", { pdf in
            pdf.obj(12, "<</ColorSpace <<" + self.rgb + ">>>>")
            pdf.stream(6, "/N 3", "profile")
            pdf.stream(20, "", "/Cs0 cs")
            pdf.stream(21, "", "0.2 0.4 0.6 sc 0 0 5 5 re f")
            pdf.stream(22, "", "0.3 0.2 0.1 sc 0 0 5 5 re f")
        }))
        for index in [0, 1] {
            let operations = try page(file, index)
            XCTAssertEqual("DeviceGray", spaceName(operations, "cs"))
            XCTAssertEqual(1, try single(operations, "sc").operands.count)
        }
    }

    func test_aStreamSharedByPagesWithDifferentSpacesIsLeftAlone() throws {
        let other = rgb.replacingOccurrences(of: "[/ICCBased 6 0 R]", with: "[/Lab <</WhitePoint [0.95 1 1.09]>>]")
        let file = try run(pages("20 0 R", "20 0 R", "<</ColorSpace <<" + rgb + ">>>>", "<</ColorSpace <<" + other + ">>>>", { pdf in
            pdf.stream(6, "/N 3", "profile")
            pdf.stream(20, "", "/Cs0 cs 0.2 0.4 0.6 sc 0 0 5 5 re f")
        }))
        let operations = try page(file, 1)
        XCTAssertEqual("Cs0", spaceName(operations, "cs"))
        XCTAssertEqual(3, try single(operations, "sc").operands.count)
    }

    func test_aStreamLeftAloneHoldsBackTheCsThatSetsItsSpace() throws {
        let file = try run(pages("[20 0 R 22 0 R]", "[21 0 R 22 0 R]", "12 0 R", "12 0 R", { pdf in
            pdf.obj(12, "<</ColorSpace <<" + self.rgb + ">>>>")
            pdf.stream(6, "/N 3", "profile")
            pdf.stream(20, "", "/Cs0 cs")
            pdf.stream(21, "", "0 g")
            pdf.stream(22, "", "0.2 0.4 0.6 sc 0 0 5 5 re f")
        }))
        let operations = try page(file, 0)
        XCTAssertEqual("Cs0", spaceName(operations, "cs"))
        XCTAssertEqual(3, try single(operations, "sc").operands.count)
    }

    func test_aMaskSharedByAnImageThatStaysInColourKeepsItsMatteLength() throws {
        let image = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask 7 0 R "
        let file = OptimizeKit.build("q 50 0 0 50 0 0 cm /Im0 Do /Im1 Do Q", "/XObject <</Im0 5 0 R /Im1 6 0 R>>", { pdf in
            pdf.stream(5, image + "/Filter /FlateDecode", TestPdf.deflate(OptimizeKit.gradient(8, 8, 3)))
            pdf.stream(6, image.replacingOccurrences(of: "8 /Height 8", with: "16 /Height 16") + "/Filter /DCTDecode", OptimizeKit.tinyJpeg)
            pdf.stream(7, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8 /Matte [1 0 0] /Filter /FlateDecode",
                       TestPdf.deflate(OptimizeKit.gradient(8, 8, 1)))
        })
        let result = try run(file)
        let after = try PdfDocument.open(result)
        XCTAssertEqual("DeviceRGB", after.name(try OptimizeKit.image(after).dictionary, "ColorSpace"))
        let mask = try XCTUnwrap(after.get(7) as? PdfStream)
        XCTAssertEqual(3, after.array(mask.dictionary, "Matte")?.items.count)
    }
}
