#if canImport(PDFKit)
import LazyPDFApp
import LazyPDFKit
import XCTest

// Mirrors windows/LazyPDF.App.Tests/WindowsPageRendererTests.cs. Skipped: the tests of the size the system reaches
// (ASizeIsRoundedToWhatTheSystemReaches, TheScaleIsMeasuredFromTheSystem) and of the bitmap header
// (ABitmapIsReadFromTheBottomRowUp, ABitmapThatIsNotThirtyTwoBitsIsRefused), which are about Windows.Data.Pdf's output
// and have no counterpart in PDFKit.

final class PdfKitRendererTests: XCTestCase {
    private func load(_ bytes: [UInt8], _ password: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> PdfKitRenderer {
        let renderer = PdfKitRenderer()
        XCTAssertTrue(renderer.load(try PdfEditSession.open(bytes, password: password), password), file: file, line: line)
        return renderer
    }

    private func dark(_ image: PdfRgbaImage) -> Int {
        (0..<image.width * image.height).filter { image.rgba[$0 * 4] < 128 }.count
    }

    private func isDark(_ image: PdfRgbaImage, _ x: Int, _ y: Int) -> Bool {
        image.rgba[(y * image.width + x) * 4] < 128
    }

    func test_thePagesAreCountedAndMeasuredInPoints() throws {
        let renderer = try load(try ApplePdfs.text(pages: 3))

        XCTAssertEqual(renderer.pageCount, 3)
        let size = renderer.pageSize(0)
        XCTAssertEqual(size.width, 595.3, accuracy: 0.5)
        XCTAssertEqual(size.height, 841.9, accuracy: 0.5)
        XCTAssertEqual(renderer.pageSize(3).width, 0)
        XCTAssertEqual(renderer.pageSize(3).height, 0)
    }

    func test_aPageIsDrawnWithTextOnWhite() throws {
        let renderer = try load(try ApplePdfs.text())

        let image = try XCTUnwrap(renderer.render(0, 72))

        XCTAssertTrue((594...596).contains(image.width))
        XCTAssertEqual(image.rgba.count, image.width * image.height * 4)
        XCTAssertEqual(image.rgba[3], 255)
        XCTAssertTrue((50...image.width * image.height / 4).contains(dark(image)))
    }

    func test_aDrawnPageIsTheRightWayUp() throws {
        let renderer = try load(try ApplePdfs.text())
        let image = try XCTUnwrap(renderer.render(0, 72))

        // The text starts at the top of the page: dark pixels in the upper half, none in the lower.
        let half = image.height / 2
        let upper = (0..<half * image.width).filter { image.rgba[$0 * 4] < 128 }.count
        let lower = (half * image.width..<image.height * image.width).filter { image.rgba[$0 * 4] < 128 }.count
        XCTAssertGreaterThan(upper, 0)
        XCTAssertEqual(lower, 0)
    }

    func test_aHigherResolutionIsBiggerByTheRatio() throws {
        let renderer = try load(try ApplePdfs.text())

        let small = try XCTUnwrap(renderer.render(0, 72))
        let large = try XCTUnwrap(renderer.render(0, 144))

        XCTAssertEqual(Double(large.width) / Double(small.width), 2, accuracy: 0.02)
    }

    func test_aRegionIsTheSameAsThatPartOfThePage() throws {
        let renderer = try load(try ApplePdfs.text(line: "Region test line."))
        let whole = try XCTUnwrap(renderer.render(0, 144))

        let tile = try XCTUnwrap(renderer.renderTile(0, 2, 0, 0, 280, 120))

        XCTAssertEqual(tile.width, 280)
        XCTAssertEqual(tile.height, 120)
        var differing = 0, compared = 0
        for y in 0..<min(tile.height, whole.height) {
            for x in 0..<min(tile.width, whole.width) {
                compared += 1
                if abs(Int(tile.rgba[(y * tile.width + x) * 4]) - Int(whole.rgba[(y * whole.width + x) * 4])) > 64 { differing += 1 }
            }
        }
        XCTAssertLessThan(Double(differing), Double(compared) * 0.02, "\(differing) of \(compared) pixels differ")
    }

    func test_aRectangleOfThePageIsDrawnAtTheAskedSize() throws {
        let renderer = try load(try ApplePdfs.text())

        let image = try XCTUnwrap(renderer.renderRegion(0, DisplayRect(36, 36, 200, 100), 144))

        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 200)
    }

    func test_aRegionOutsideThePageIsWhite() throws {
        let renderer = try load(ApplePdfs.square())

        let image = try XCTUnwrap(renderer.renderRegion(0, DisplayRect(150, 50, 100, 100), 72))

        XCTAssertEqual(dark(image), 0)
    }

    func test_aPageThatIsNotThereGivesNothing() throws {
        let renderer = try load(try ApplePdfs.text())

        XCTAssertNil(renderer.render(5, 72))
        XCTAssertNil(renderer.render(-1, 72))
        XCTAssertNil(renderer.render(0, 0))
    }

    func test_aDocumentThatWasNeverLoadedDrawsNothing() {
        let renderer = PdfKitRenderer()

        XCTAssertNil(renderer.render(0, 72))
        XCTAssertEqual(renderer.pageCount, 0)
    }

    func test_aClosedRendererDrawsNothing() throws {
        let renderer = try load(try ApplePdfs.text())

        renderer.close()

        XCTAssertNil(renderer.render(0, 72))
        XCTAssertEqual(renderer.pageCount, 0)
    }

    func test_afterACommitTheNewFileIsWhatIsDrawn() throws {
        let session = try PdfEditSession.open(try ApplePdfs.text(pages: 1))
        let renderer = PdfKitRenderer()
        XCTAssertTrue(renderer.load(session, nil))
        XCTAssertEqual(renderer.pageCount, 1)

        try PageOperations.insertBlank(session.document, 1, 612, 792)
        _ = try session.commit("Add a page")
        XCTAssertTrue(renderer.load(session, nil))

        XCTAssertEqual(renderer.pageCount, 2)
        XCTAssertEqual(renderer.pageSize(1).width, 612, accuracy: 0.5)
    }

    func test_aFileWithAPasswordIsDrawnOnceItIsOpened() throws {
        let renderer = try load(try ApplePdfs.fixture("locked.pdf"), "secret")

        XCTAssertNotNil(renderer.render(0, 72))
    }

    func test_aFileOnlyTheOwnerRestrictsIsDrawnWithNoPassword() throws {
        let renderer = try load(try ApplePdfs.fixture("owner-only-aes.pdf"))

        XCTAssertNotNil(renderer.render(0, 72))
    }

    func test_anAes256FileIsDecryptedByTheEngineBeforeTheSystemSeesIt() throws {
        let bytes = try ApplePdfs.fixture("crypt-aes256.pdf")
        let revision = try PdfEditSession.open(bytes, password: "secret").document.security?.revision ?? 0
        XCTAssertGreaterThanOrEqual(revision, 6, "the fixture is a revision 6 file")

        let renderer = try load(bytes, "secret")

        XCTAssertNotNil(renderer.render(0, 72))
    }

    func test_aPageIsDrawnWithItsSquareWhereThePageHasIt() throws {
        let image = try XCTUnwrap(try load(ApplePdfs.square()).render(0, 72))

        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
        XCTAssertTrue(isDark(image, 5, 95))
        XCTAssertFalse(isDark(image, 5, 5))
        XCTAssertFalse(isDark(image, 195, 95))
    }

    func test_aRotatedPageIsTurnedClockwise() throws {
        let renderer = try load(ApplePdfs.square(rotate: 90))
        let image = try XCTUnwrap(renderer.render(0, 72))

        XCTAssertEqual(renderer.pageSize(0).width, 100, accuracy: 0.5)
        XCTAssertEqual(renderer.pageSize(0).height, 200, accuracy: 0.5)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 200)
        XCTAssertTrue(isDark(image, 5, 5))
        XCTAssertFalse(isDark(image, 95, 195))
    }

    func test_theCropBoxIsWhatIsShown() throws {
        let renderer = try load(ApplePdfs.square(crop: [25, 25, 125, 75]))
        let image = try XCTUnwrap(renderer.render(0, 72))

        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 50)
        XCTAssertTrue(isDark(image, 5, 45))
        XCTAssertFalse(isDark(image, 45, 45))
        XCTAssertFalse(isDark(image, 5, 5))
    }

    func test_aCropBoxBesideTheSquareShowsNone() throws {
        let image = try XCTUnwrap(try load(ApplePdfs.square(crop: [50, 0, 200, 100])).render(0, 72))

        XCTAssertEqual(image.width, 150)
        XCTAssertEqual(dark(image), 0)
    }

    func test_aPageOfUserUnitTwoIsTwiceTheSize() throws {
        let renderer = try load(ApplePdfs.square(unit: 2))
        let image = try XCTUnwrap(renderer.render(0, 72))

        XCTAssertEqual(renderer.pageSize(0).width, 400, accuracy: 0.5)
        XCTAssertEqual(renderer.pageSize(0).height, 200, accuracy: 0.5)
        XCTAssertEqual(image.width, 400)
        XCTAssertTrue(isDark(image, 50, 150))
        XCTAssertFalse(isDark(image, 150, 150))
    }
}
#endif
