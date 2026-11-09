import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/standards/FigureDescriptionTests.cs: tagging a picture file, finding its figure and
// the box it covers, and writing its description. The picture of a figure (FigurePictures) is new on Apple and has its own tests
// below.

final class FigureDescriptionTests: XCTestCase {
    private func pictureFile() throws -> [UInt8] {
        try PdfFromPictures.create([[1]], FakeCodec()).bytes
    }

    // The figure is marked on the page and drawn by a form, the usual shape of a chart or a placed graphic.
    private func formFigure() -> [UInt8] {
        var file = "%PDF-1.7\n"
        var offsets: [Int] = []
        func obj(_ body: String) {
            offsets.append(file.utf8.count)
            file += "\(offsets.count) 0 obj\n\(body)\nendobj\n"
        }
        func stream(_ entries: String, _ data: String) {
            obj("<<\(entries) /Length \(data.utf8.count)>>\nstream\n\(data)\nendstream")
        }
        obj("<</Type /Catalog /Pages 2 0 R /MarkInfo <</Marked true>> /StructTreeRoot 6 0 R>>")
        obj("<</Type /Pages /Kids [3 0 R] /Count 1>>")
        obj("<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources <</XObject <</Fm1 5 0 R>>>> /StructParents 0>>")
        stream("", "/Figure <</MCID 0>> BDC /Fm1 Do EMC")
        stream("/Type /XObject /Subtype /Form /BBox [0 0 612 792]", "0.5 g 100 100 200 150 re f")
        obj("<</Type /StructTreeRoot /K 7 0 R /ParentTree <</Nums [0 [7 0 R]]>>>>")
        obj("<</Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 0>>")
        let xref = file.utf8.count
        file += "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(repeating: "0", count: 10 - String(offset).count) + "\(offset) 00000 n \n" }
        file += "trailer\n<</Size \(offsets.count + 1) /Root 1 0 R>>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(file.utf8)
    }

    func test_aFigureMarkedOnThePageAndDrawnByAFormStillHasItsBox() throws {
        let document = try PdfDocument.open(formFigure())
        let figures = FigureFinder.list(try XCTUnwrap(StructureTree.read(document)))
        XCTAssertEqual(figures.count, 1)

        let box = try XCTUnwrap(FigureFinder.box(document, figures[0].element, figures[0].page))

        XCTAssertEqual(box.width, 200, accuracy: 1)
        XCTAssertEqual(box.height, 150, accuracy: 1)
    }

    func test_replacementTextCountsAsADescriptionAndAFigureWithoutAPageHasNoPageNumber() throws {
        let document = try PdfDocument.open(formFigure())
        let element = FigureFinder.list(try XCTUnwrap(StructureTree.read(document)))[0].element
        element.actualText = "A chart of sales."

        let row = FigureRow(element, -1, 3)

        XCTAssertFalse(row.hasAlt)
        XCTAssertTrue(row.hasDescription)
        XCTAssertEqual(row.summary, "A chart of sales.")
        XCTAssertEqual(row.title, "Figure 3")
    }

    func test_everyFigureIsListedHoweverManyThereAre() throws {
        let tree = try XCTUnwrap(StructureTree.read(PdfDocument.open(formFigure())))
        for _ in 0..<700 { try tree.add(tree.roots[0], StructElement("Figure")) }

        XCTAssertEqual(FigureFinder.list(tree).count, 701)
    }

    func test_addingTagsToAPictureMakesAFigureWithoutADescription() throws {
        let document = try PdfDocument.open(pictureFile())

        let result = try AutoTagger.tag(document)
        let figures = FigureFinder.list(try XCTUnwrap(StructureTree.read(document)))

        XCTAssertEqual(result.figures, 1)
        XCTAssertEqual(figures.count, 1)
        XCTAssertEqual(figures[0].page, 0)
        XCTAssertFalse(figures[0].hasAlt)
        XCTAssertEqual(figures[0].summary, "No description")
        XCTAssertEqual(figures[0].title, "Figure 1, page 1")
    }

    func test_theFigureBoxIsWhereThePictureIsDrawnOnThePage() throws {
        let document = try PdfDocument.open(pictureFile())
        _ = try AutoTagger.tag(document)
        let figure = FigureFinder.list(try XCTUnwrap(StructureTree.read(document)))[0]

        let box = try XCTUnwrap(FigureFinder.box(document, figure.element, figure.page))

        let page = PageGeometry(document.pages[0])
        XCTAssertTrue(box.width > 0 && box.height > 0)
        XCTAssertTrue((-0.5...page.width).contains(box.x))
        XCTAssertTrue((-0.5...page.height).contains(box.y))
        XCTAssertLessThanOrEqual(box.x + box.width, page.width + 0.5)
        XCTAssertLessThanOrEqual(box.y + box.height, page.height + 0.5)
    }

    @MainActor
    func test_aDescriptionIsSavedAsOneStepAndPassesTheFigureCheck() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.dir.file("picture.pdf", try pictureFile()))
        let tab = f.vm.activeDocument!
        _ = try AutoTagger.tag(tab.document)
        XCTAssertTrue(try tab.commit("Add tags"))
        XCTAssertEqual(try AccessibilityChecker.check(tab.document)[.figureAlt].status, .failed)

        let tree = try XCTUnwrap(StructureTree.read(tab.document))
        let figure = FigureFinder.list(tree)[0]
        try AccessibilityEdits.setAlt(tab.document, tree, figure.element, "  A grey square.  ")
        XCTAssertTrue(try tab.commit("Figure description"))

        let again = FigureFinder.list(try XCTUnwrap(StructureTree.read(tab.document)))[0]
        XCTAssertEqual(again.alt, "A grey square.")
        XCTAssertEqual(try AccessibilityChecker.check(tab.document)[.figureAlt].status, .passed)
    }

    @MainActor
    func test_anEmptyDescriptionTakesTheOldOneAway() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.dir.file("picture.pdf", try pictureFile()))
        let tab = f.vm.activeDocument!
        _ = try AutoTagger.tag(tab.document)
        var tree = try XCTUnwrap(StructureTree.read(tab.document))
        try AccessibilityEdits.setAlt(tab.document, tree, FigureFinder.list(tree)[0].element, "Words")
        try tab.commit("Figure description")

        tree = try XCTUnwrap(StructureTree.read(tab.document))
        try AccessibilityEdits.setAlt(tab.document, tree, FigureFinder.list(tree)[0].element, " ")
        try tab.commit("Figure description")

        XCTAssertFalse(FigureFinder.list(try XCTUnwrap(StructureTree.read(tab.document)))[0].hasAlt)
    }

    func test_aFileWithoutTagsHasNoFigures() throws {
        XCTAssertNil(StructureTree.read(try PdfDocument.open(Pdfs.text())))
    }

    // FigurePictures: only the cut of a picture is new on Apple; the box is found as above.

    func test_theCutTakesTheRegionOfThePictureInPixels() throws {
        var rgba = [UInt8](repeating: 0, count: 10 * 20 * 4)
        for y in 0..<20 { for x in 0..<10 { rgba[(y * 10 + x) * 4] = UInt8(x + y * 10) } }
        let image = PdfRgbaImage(10, 20, rgba)

        let cut = try XCTUnwrap(FigurePictures.crop(image, DisplayRect(2, 3, 4, 5), 1, 1))

        XCTAssertEqual(cut.width, 4)
        XCTAssertEqual(cut.height, 5)
        XCTAssertEqual(cut.rgba[0], UInt8(2 + 3 * 10))
        XCTAssertEqual(cut.rgba[(4 * 4 + 3) * 4], UInt8(5 + 7 * 10))
    }

    func test_theCutIsClippedToThePictureAndNothingOutsideIsNil() throws {
        let image = PdfRgbaImage(10, 20, [UInt8](repeating: 9, count: 10 * 20 * 4))

        let edge = try XCTUnwrap(FigurePictures.crop(image, DisplayRect(-5, 15, 8, 10), 1, 1))
        XCTAssertEqual(edge.width, 3)
        XCTAssertEqual(edge.height, 5)
        XCTAssertNil(FigurePictures.crop(image, DisplayRect(30, 30, 5, 5), 1, 1))
    }

    func test_theCutFollowsThePixelsToThePoint() throws {
        let image = PdfRgbaImage(20, 40, [UInt8](repeating: 9, count: 20 * 40 * 4))

        let cut = try XCTUnwrap(FigurePictures.crop(image, DisplayRect(2, 3, 4, 5), 2, 2))

        XCTAssertEqual(cut.width, 8)
        XCTAssertEqual(cut.height, 10)
    }

    func test_thePictureOfAFigureIsDrawnFromItsBox() throws {
        let document = try PdfDocument.open(formFigure())
        let figure = FigureFinder.list(try XCTUnwrap(StructureTree.read(document)))[0]

        let picture = try XCTUnwrap(FigurePictures.picture(document, figure.element, figure.page, FakeRenderer(), NSLock()))

        XCTAssertGreaterThan(picture.width, 0)
        XCTAssertGreaterThan(picture.height, 0)
    }
}
