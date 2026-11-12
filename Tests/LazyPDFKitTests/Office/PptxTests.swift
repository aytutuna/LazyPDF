import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/PptxTests.cs and reads the same golden files.

final class PptxTests: XCTestCase {
    private func layout(_ package: [UInt8], _ limits: PptxLimits = .standard) throws -> LayoutResult {
        try PptxLayout.run(try PptxReader.read(package, limits), LayoutFonts(OfficeLayoutSpec.fonts()))
    }

    private func problem(_ work: () throws -> Void) -> PdfReadProblem? {
        do {
            try work()
            return nil
        } catch let e as PdfReadException {
            return e.problem
        } catch {
            return nil
        }
    }

    private func box(_ name: String, _ text: String, x: Int = 0, y: Int = 0) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"\(name)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"3048000\" cy=\"457200\"/></a:xfrm><a:prstGeom prst=\"rect\"/></p:spPr>"
            + "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>"
    }

    private func slides(_ count: Int, _ shapes: String) throws -> [UInt8] {
        try PptxSpec.one((1...count).map { "@slide\($0)\n<p:cSld><p:spTree>\(shapes)</p:spTree></p:cSld>\n" }.joined())
    }

    private func texts(_ page: LayoutPage) -> [PlacedText] {
        page.boxes.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
    }

    private func rects(_ page: LayoutPage) -> [PlacedRect] {
        page.boxes.compactMap { if case .rect(let r) = $0 { return r } else { return nil } }
    }

    func test_slideLayoutGoldenFile() throws {
        var output = ""
        for (name, package) in try PptxSpec.read(try Golden.input("office-pptx", "pptx-input.txt")) {
            output += "> \(name)\n" + PptxSpec.dump(try layout(package))
        }
        try Golden.check("office-pptx", "pptx-output.txt", output)
    }

    func test_onePagePerSlideAtTheSlideSizeWithoutTheHiddenOnes() throws {
        let package = try PptxSpec.one("@presentation\n<p:sldSz cx=\"12192000\" cy=\"6858000\"/>\n@slide1\n<p:cSld><p:spTree/></p:cSld>\n@slide2 show=0\n<p:cSld><p:spTree/></p:cSld>\n@slide3\n<p:cSld><p:spTree/></p:cSld>\n")
        let made = try layout(package)
        XCTAssertEqual(made.pages.count, 2)
        for page in made.pages {
            XCTAssertEqual(page.width, 960)
            XCTAssertEqual(page.height, 540)
        }
        XCTAssertEqual(made.skipped, [SkippedFeature("hidden-slide", 1)])
    }

    func test_themeColorsFollowThePublishedOfficeShades() throws {
        let made = try layout(try PptxSpec.one(
            "@slide1\n<p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val=\"accent1\"><a:lumMod val=\"75000\"/></a:schemeClr></a:solidFill></p:bgPr></p:bg><p:spTree>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"B\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"100\" cy=\"100\"/></a:xfrm><a:prstGeom prst=\"rect\"/><a:solidFill><a:schemeClr val=\"bg1\"><a:lumMod val=\"95000\"/></a:schemeClr></a:solidFill></p:spPr></p:sp>"
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"C\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"100\" cy=\"100\"/></a:xfrm><a:prstGeom prst=\"rect\"/><a:solidFill><a:schemeClr val=\"accent1\"><a:lumMod val=\"60000\"/><a:lumOff val=\"40000\"/></a:schemeClr></a:solidFill></p:spPr></p:sp>"
            + "</p:spTree></p:cSld>\n"))
        let colors = rects(made.pages[0]).map { $0.color }
        XCTAssertEqual(Array(colors.dropFirst()), [0xF2F2F2, 0x95B3D7])
        // Office rounds lightness to a 240 step scale, so its darker shade (366092) is a few steps off the exact one.
        for shift in [16, 8, 0] {
            XCTAssertLessThanOrEqual(abs((colors[0] >> shift & 0xFF) - (0x366092 >> shift & 0xFF)), 4)
        }
    }

    func test_thePlaceholderTakesPositionAndStyleFromTheLayoutAndMaster() throws {
        let parts = try PptxSpec.read(try Golden.input("office-pptx", "pptx-input.txt"))
        let made = try layout(parts.first { $0.name.hasPrefix("placeholders") }!.package)
        let title = texts(made.pages[0]).first { $0.text == "A title" }!
        XCTAssertEqual(title.size, 44)
        XCTAssertEqual(title.family, "Cambria")
        XCTAssertEqual(title.color, 0x1F497D)
        XCTAssertTrue(title.style.contains(.bold))
        let first = texts(made.pages[0]).first { $0.text == "First point" }!
        XCTAssertEqual(first.size, 28)
        XCTAssertGreaterThan(first.x, 36 + 14.4 - 0.01)
    }

    func test_anEmptyPlaceholderDrawsNothing() throws {
        let package = try PptxSpec.one("@slide1\n<p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"T\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr/></a:p></p:txBody></p:sp></p:spTree></p:cSld>\n")
        let made = try layout(package)
        XCTAssertTrue(made.pages[0].boxes.isEmpty)
        XCTAssertTrue(made.skipped.isEmpty)
    }

    func test_thePowerPointConverterWritesAPageForEverySlide() throws {
        let package = try PptxSpec.one("@slide1\n<p:cSld><p:spTree>" + box("A", "First slide") + "</p:spTree></p:cSld>\n@slide2\n<p:cSld><p:spTree>" + box("B", "Second slide") + "</p:spTree></p:cSld>\n")
        let made = try OfficeConverter.fromPowerPoint(package, OfficeLayoutSpec.fonts())
        XCTAssertEqual(made.pages, 2)
        let pdf = try PdfDocument.open(made.bytes)
        XCTAssertTrue(TextPage.create(pdf, pdf.pages[0]).text.contains("First slide"))
        XCTAssertTrue(TextPage.create(pdf, pdf.pages[1]).text.contains("Second slide"))
        let media = pdf.pages[0].mediaBox
        XCTAssertEqual(media.right - media.left, 720, accuracy: 0.01)
    }

    func test_anOldPowerPointFileIsRefusedWithAHint() {
        let ole: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0]
        XCTAssertEqual(problem { _ = try PptxReader.read(ole) }, .unsupported)
    }

    func test_aPackageThatIsNotAPresentationIsRefused() throws {
        let workbook = try XlsxSpec.package([(key: "workbook", text: "<sheets/>")])
        XCTAssertEqual(problem { _ = try PptxReader.read(workbook) }, .unsupported)
    }

    func test_allSlidesHiddenLeavesNothingToShow() throws {
        let package = try PptxSpec.one("@slide1 show=0\n<p:cSld><p:spTree/></p:cSld>\n")
        XCTAssertEqual(problem { _ = try layout(package) }, .unsupported)
    }

    func test_moreSlidesThanTheLimitAreRefused() throws {
        let package = try slides(3, "")
        XCTAssertEqual(try layout(package, PptxLimits(maxSlides: 3)).pages.count, 3)
        XCTAssertEqual(problem { _ = try layout(package, PptxLimits(maxSlides: 2)) }, .unsupported)
    }

    func test_shapesPastTheLimitAreCountedNotRead() throws {
        let package = try slides(1, box("A", "one") + box("B", "two") + box("C", "three"))
        let made = try layout(package, PptxLimits(maxShapes: 2))
        XCTAssertEqual(texts(made.pages[0]).count, 2)
        XCTAssertEqual(made.skipped, [SkippedFeature("slide-shape", 1)])
    }

    func test_paragraphsAndTextPastTheLimitAreCutAndNoted() throws {
        func body(_ inside: String) -> String {
            "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"T\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"3048000\" cy=\"457200\"/></a:xfrm><a:prstGeom prst=\"rect\"/></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>\(inside)</p:txBody></p:sp>"
        }
        let paragraphs = try slides(1, body("<a:p><a:r><a:t>a</a:t></a:r></a:p><a:p><a:r><a:t>b</a:t></a:r></a:p><a:p><a:r><a:t>c</a:t></a:r></a:p>"))
        let cutParagraphs = try layout(paragraphs, PptxLimits(maxParagraphs: 2))
        XCTAssertEqual(texts(cutParagraphs.pages[0]).map { $0.text }, ["a", "b"])
        XCTAssertEqual(cutParagraphs.skipped, [SkippedFeature("slide-text-cut", 1)])

        let text = try slides(1, body("<a:p><a:r><a:t>ab\u{1F600}cd</a:t></a:r></a:p>"))
        let cut = try layout(text, PptxLimits(maxTextLength: 3))
        XCTAssertEqual(texts(cut.pages[0]).map { $0.text }, ["ab"])
        XCTAssertEqual(cut.skipped, [SkippedFeature("slide-text-cut", 1)])
    }

    func test_tooMuchTextInAllIsRefused() throws {
        let package = try slides(2, box("A", "abcd"))
        _ = try layout(package, PptxLimits(maxTotalText: 8))
        XCTAssertEqual(problem { _ = try layout(package, PptxLimits(maxTotalText: 7)) }, .unsupported)
    }

    func test_sharedMasterShapesCountTowardTheDrawnLimitOnEverySlide() throws {
        let master = "@master1\n<p:cSld><p:spTree>" + box("M", "mark") + box("N", "mark") + "</p:spTree></p:cSld>\n"
        let package = try PptxSpec.one(master + "@slide1\n<p:cSld><p:spTree/></p:cSld>\n@slide2\n<p:cSld><p:spTree/></p:cSld>\n")
        XCTAssertEqual(try layout(package, PptxLimits(maxDrawnShapes: 4)).pages.count, 2)
        XCTAssertEqual(problem { _ = try layout(package, PptxLimits(maxDrawnShapes: 3)) }, .unsupported)
    }

    func test_aSlideWhoseLayoutIsMissingIsStillDrawn() throws {
        let package = try PptxSpec.one("@slide1 layout=9\n<p:cSld><p:spTree>" + box("A", "kept") + "</p:spTree></p:cSld>\n")
        XCTAssertTrue(texts(try layout(package).pages[0]).contains { $0.text == "kept" })
    }

    func test_thePageBoxesOfAFarOutShapeStayFinite() throws {
        let package = try slides(1, box("A", "far", x: Int(Int32.max), y: Int(Int32.min)))
        let made = try layout(package)
        for t in texts(made.pages[0]) { XCTAssertTrue(t.x.isFinite && t.baseline.isFinite) }
    }
}
