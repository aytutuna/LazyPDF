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

    func test_rightToLeftSlideGoldenFile() throws {
        var output = ""
        for (name, package) in try PptxSpec.read(try Golden.input("office-pptx", "rtl-input.txt")) {
            let made = try PptxLayout.run(try PptxReader.read(package), LayoutFonts(OfficeLayoutSpec.scriptFonts()))
            output += "> \(name)\n" + PptxSpec.dump(made)
        }
        try Golden.check("office-pptx", "rtl-output.txt", output)
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

    func test_sharedMasterTextCountsTowardTheTotalOnEverySlide() throws {
        let master = "@master1\n<p:cSld><p:spTree>" + box("M", "mark") + box("N", "mark") + "</p:spTree></p:cSld>\n"
        let package = try PptxSpec.one(master + "@slide1\n<p:cSld><p:spTree/></p:cSld>\n@slide2\n<p:cSld><p:spTree/></p:cSld>\n")
        _ = try layout(package, PptxLimits(maxTotalText: 24))
        XCTAssertEqual(problem { _ = try layout(package, PptxLimits(maxTotalText: 23)) }, .unsupported)
    }

    func test_aSlideWhoseLayoutRelationshipPointsAtAMasterIsStillDrawn() throws {
        let package = try PptxSpec.one("@slide1\n<p:cSld><p:spTree/></p:cSld>\n@slide2 layout=/../../slideMasters/slideMaster1\n<p:cSld><p:spTree>" + box("A", "kept") + "</p:spTree></p:cSld>\n");
        let pages = try layout(package).pages
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(texts(pages[1]).contains { $0.text == "kept" })
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

    private let jpeg = "ffd8ffc0000b080003000401011100ffd9"
    private let image = "<Relationship Id=\"rIdP\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/pic.jpg\"/>"

    private func pic(_ x: Int, rotated: Bool = false) -> String {
        "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"P\"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rIdP\"/></p:blipFill><p:spPr><a:xfrm\(rotated ? " rot=\"5400000\"" : "")><a:off x=\"\(x)\" y=\"0\"/><a:ext cx=\"1270000\" cy=\"635000\"/></a:xfrm></p:spPr></p:pic>"
    }

    private func withPictures(_ shapes: String) throws -> [UInt8] {
        try PptxSpec.one("@slide1\n<p:cSld><p:spTree>\(shapes)</p:spTree></p:cSld>\n@rels slide1\n\(image)\n@bytes ppt/media/pic.jpg\n\(jpeg)\n")
    }

    private func group(_ depth: Int, _ inside: String) -> String {
        depth == 0 ? inside : group(depth - 1, "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"\(depth)\" name=\"G\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"635000\" cy=\"635000\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"635000\" cy=\"635000\"/></a:xfrm></p:grpSpPr>\(inside)</p:grpSp>")
    }

    private func table(_ rows: Int, _ columns: Int) -> String {
        let cell = "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>x</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>"
        let grid = String(repeating: "<a:gridCol w=\"635000\"/>", count: columns)
        let row = "<a:tr h=\"254000\">" + String(repeating: cell, count: columns) + "</a:tr>"
        return "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"2\" name=\"T\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"1\" cy=\"1\"/></p:xfrm>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblGrid>\(grid)</a:tblGrid>\(String(repeating: row, count: rows))</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    private func images(_ page: LayoutPage) -> [PlacedImage] {
        page.boxes.compactMap { if case .image(let i) = $0 { return i } else { return nil } }
    }

    func test_shapeLayoutGoldenFile() throws {
        var output = ""
        for (name, package) in try PptxSpec.read(try Golden.input("office-pptx", "shapes-input.txt")) {
            output += "> \(name)\n" + PptxSpec.dump(try layout(package))
        }
        try Golden.check("office-pptx", "shapes-output.txt", output)
    }

    func test_shapeContentGoldenFile() throws {
        var output = ""
        for (name, package) in try PptxSpec.read(try Golden.input("office-pptx", "shapes-input.txt")) {
            var contents: [[UInt8]] = []
            _ = try OfficePdfWriter.create(try layout(package), OfficeLayoutSpec.fonts(), contents: { _, bytes in contents.append(bytes) })
            output += "> \(name)\n"
            for page in contents {
                output += "page\n"
                var text = Latin1.string(page)
                while text.hasSuffix("\n") { text.removeLast() }
                for line in text.components(separatedBy: "\n") { output += "| \(line)\n" }
            }
        }
        try Golden.check("office-pptx", "shapes-content.txt", output)
    }

    func test_aPictureInAPlaceholderTakesItsFrameFromTheLayout() throws {
        let layoutShape = "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Pic\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"pic\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"127000\" y=\"0\"/><a:ext cx=\"1270000\" cy=\"635000\"/></a:xfrm></p:spPr></p:sp>"
        let pic = "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"P\"/><p:cNvPicPr/><p:nvPr><p:ph type=\"pic\" idx=\"1\"/></p:nvPr></p:nvPicPr><p:blipFill><a:blip r:embed=\"rIdP\"/></p:blipFill><p:spPr/></p:pic>"
        let package = try PptxSpec.one("@layout1\n<p:cSld><p:spTree>\(layoutShape)</p:spTree></p:cSld>\n@slide1\n<p:cSld><p:spTree>\(pic)</p:spTree></p:cSld>\n@rels slide1\n\(image)\n@bytes ppt/media/pic.jpg\n\(jpeg)\n")
        let made = try layout(package)
        XCTAssertTrue(made.skipped.isEmpty)
        let placed = images(made.pages[0])
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed[0].x, 10, accuracy: 0.01)
        XCTAssertEqual(placed[0].width, 100, accuracy: 0.01)
    }

    func test_aJpegOnASlideIsPlacedAtItsFrameAndRotated() throws {
        let made = try OfficeConverter.fromPowerPoint(try withPictures(pic(127000)), OfficeLayoutSpec.fonts())
        XCTAssertTrue(made.skipped.isEmpty)
        let placed = images(try layout(try withPictures(pic(127000))).pages[0])
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed[0].x, 10, accuracy: 0.01)
        XCTAssertEqual(placed[0].width, 100, accuracy: 0.01)
        XCTAssertEqual(placed[0].height, 50, accuracy: 0.01)

        var contents: [[UInt8]] = []
        _ = try OfficePdfWriter.create(try layout(try withPictures(pic(0, rotated: true))), OfficeLayoutSpec.fonts(), contents: { _, bytes in contents.append(bytes) })
        XCTAssertTrue(Latin1.string(contents[0]).contains("0 -1 1 0 "))
    }

    func test_otherPicturesNeedTheCodec() throws {
        let package = try PptxSpec.one("@slide1\n<p:cSld><p:spTree>\(pic(0))</p:spTree></p:cSld>\n@rels slide1\n\(image)\n@bytes ppt/media/pic.jpg\n50020280808080\n")
        let with = try OfficeConverter.fromPowerPoint(package, OfficeLayoutSpec.fonts(), ExportFakeCodec())
        XCTAssertTrue(with.skipped.isEmpty)
        let without = try OfficeConverter.fromPowerPoint(package, OfficeLayoutSpec.fonts())
        XCTAssertEqual(without.skipped, [SkippedFeature("picture", 1)])
    }

    func test_picturesPastTheLimitAreCounted() throws {
        let made = try layout(try withPictures(pic(0) + pic(127000) + pic(254000)), PptxLimits(maxPictures: 2))
        XCTAssertEqual(images(made.pages[0]).count, 2)
        XCTAssertEqual(made.skipped, [SkippedFeature("picture", 1)])
    }

    func test_groupsDeeperThanTheLimitAreCountedWithTheirContent() throws {
        let leaf = box("Leaf", "deep")
        let within = try layout(try slides(1, group(2, leaf)), PptxLimits(maxGroupDepth: 2))
        XCTAssertEqual(texts(within.pages[0]).count, 1)
        let beyond = try layout(try slides(1, group(3, leaf) + box("Kept", "kept")), PptxLimits(maxGroupDepth: 2))
        XCTAssertEqual(texts(beyond.pages[0]).map { $0.text }, ["kept"])
        XCTAssertEqual(beyond.skipped, [SkippedFeature("slide-shape", 1)])
    }

    func test_shapesInsideGroupsCountTowardTheShapeLimit() throws {
        let made = try layout(try slides(1, group(1, box("A", "one") + box("B", "two") + box("C", "three"))), PptxLimits(maxShapes: 3))
        XCTAssertEqual(texts(made.pages[0]).map { $0.text }, ["one", "two"])
        XCTAssertEqual(made.skipped, [SkippedFeature("slide-shape", 1)])
    }

    func test_aTableWithinTheLimitsIsDrawnAndOneBeyondThemIsCounted() throws {
        let limits = PptxLimits(maxTableRows: 3, maxTableColumns: 2)
        let fits = try layout(try slides(1, table(3, 2)), limits)
        XCTAssertEqual(texts(fits.pages[0]).count, 6)
        XCTAssertTrue(fits.skipped.isEmpty)

        let tooManyRows = try layout(try slides(1, table(4, 2) + box("A", "kept")), limits)
        XCTAssertEqual(texts(tooManyRows.pages[0]).map { $0.text }, ["kept"])
        XCTAssertEqual(tooManyRows.skipped, [SkippedFeature("slide-shape", 1)])
        XCTAssertEqual(try layout(try slides(1, table(2, 3) + box("A", "kept")), limits).skipped, [SkippedFeature("slide-shape", 1)])
    }

    func test_aCellUnderAnEarlierSpanIsIgnored() throws {
        let overlapping = table(2, 2).replacingOccurrences(of: "<a:tc>", with: "<a:tc gridSpan=\"2\" rowSpan=\"2\">")
        XCTAssertEqual(texts(try layout(try slides(1, overlapping)).pages[0]).count, 1)
    }

    func test_aTableCountsItsTextTowardTheTotal() throws {
        _ = try layout(try slides(1, table(2, 2)), PptxLimits(maxTotalText: 4))
        let package = try slides(1, table(2, 2))
        XCTAssertEqual(problem { _ = try layout(package, PptxLimits(maxTotalText: 3)) }, .unsupported)
    }

    func test_shapesAndTablesAreWrittenToThePdf() throws {
        let shapes = table(2, 2)
            + "<p:sp><p:nvSpPr><p:cNvPr id=\"5\" name=\"S\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm rot=\"2700000\"><a:off x=\"2540000\" y=\"2540000\"/><a:ext cx=\"1270000\" cy=\"635000\"/></a:xfrm><a:prstGeom prst=\"homePlate\"/>"
            + "<a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill><a:ln w=\"12700\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill><a:prstDash val=\"dash\"/></a:ln></p:spPr></p:sp>"
        var contents: [[UInt8]] = []
        let made = try OfficePdfWriter.create(try layout(try slides(1, shapes)), OfficeLayoutSpec.fonts(), contents: { _, bytes in contents.append(bytes) })
        XCTAssertTrue(made.skipped.isEmpty)
        let content = Latin1.string(contents[0])
        XCTAssertTrue(content.contains("[4 3] 0 d"))
        XCTAssertTrue(content.contains("\nB\n"))
        let pdf = try PdfDocument.open(made.bytes)
        XCTAssertEqual(TextPage.create(pdf, pdf.pages[0]).text.filter { $0 == "x" }.count, 4)
    }
}
