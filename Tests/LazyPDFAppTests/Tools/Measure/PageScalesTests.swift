import XCTest
@testable import LazyPDFKit
@testable import LazyPDFApp

// Mirrors the PageScales tests in windows/LazyPDF.App.Tests/Tools/measure/MeasurePendingTests.cs.

final class PageScalesTests: XCTestCase {
    private let start = MeasureScale(1, .millimetre, 2, .metre)
    private let typed = MeasureScale(1, .millimetre, 5, .metre)

    private func writtenOn(pages: Int, page: Int, _ scale: MeasureScale) throws -> PdfDocument {
        let session = try PdfEditSession.open(Pdfs.text(pages))
        let line = MeasureItem(.distance, page, [ViewPoint(100, 100), ViewPoint(172, 100)])
        _ = try MeasureWriter.write(session.document, [line], { _ in scale }, author: "Sam", date: DateTimeOffset(2026, 1, 5, 9, 0, 0))
        XCTAssertTrue(try session.commit("Measure"))
        return try PdfDocument.open(session.current)
    }

    func test_aPageScaleFollowsThePageAndYieldsToWhatWasTypedForIt() throws {
        let document = try PdfDocument.open(Pdfs.text(3))
        let scales = PageScales(start)

        scales.set(PageScales.key(document, 1), typed)
        XCTAssertEqual([0, 1, 2].map { scales.scale(document, $0) }, [start, typed, start])

        try PageOperations.delete(document, [0])
        XCTAssertEqual(scales.scale(document, 0), typed)

        let all = MeasureScale(1, .centimetre, 1, .metre)
        scales.setAll(all)
        XCTAssertEqual([0, 1].map { scales.scale(document, $0) }, [all, all])
        XCTAssertEqual(scales.scale(document, 5), all)
    }

    func test_aScaleWrittenOnAPageBeatsTheFileDefault() throws {
        let found = MeasureScale(1, .millimetre, 100, .millimetre)
        let document = try writtenOn(pages: 2, page: 1, found)
        let scales = PageScales(.actual)

        XCTAssertEqual(scales.scale(document, 0), .actual)
        XCTAssertEqual(scales.scale(document, 1), found)
        scales.set(PageScales.key(document, 1), typed)
        XCTAssertEqual(scales.scale(document, 1), typed)
    }

    func test_useForAllBeatsAScaleWrittenOnThePage() throws {
        let found = MeasureScale(1, .millimetre, 100, .millimetre)
        let all = MeasureScale(1, .millimetre, 50, .millimetre)
        let document = try writtenOn(pages: 2, page: 1, found)
        let scales = PageScales(.actual)
        XCTAssertEqual(scales.scale(document, 1), found)

        scales.setAll(all)

        XCTAssertEqual(scales.scale(document, 1), all)
    }

    func test_whatWasFoundIsKeptUntilForgotten() throws {
        let document = try writtenOn(pages: 2, page: 1, MeasureScale(1, .millimetre, 100, .millimetre))
        let scales = PageScales(.actual)
        XCTAssertEqual(scales.scale(document, 1).real, 100)

        let bare = try PdfDocument.open(Pdfs.text(2))
        XCTAssertEqual(scales.scale(bare, 1).real, 100)
        scales.forgetFound()
        XCTAssertEqual(scales.scale(bare, 1), .actual)
    }

    func test_otherScalesAreCountedOnPagesThatAreStillThere() throws {
        let document = try writtenOn(pages: 4, page: 2, MeasureScale(1, .millimetre, 100, .millimetre))
        let scales = PageScales(.actual)
        scales.set(PageScales.key(document, 0), typed)
        scales.set(12345, typed)

        XCTAssertEqual(scales.otherScaleCount(except: PageScales.key(document, 1), document), 2)
        XCTAssertEqual(scales.otherScaleCount(except: PageScales.key(document, 0), document), 1)
        scales.setAll(typed)
        XCTAssertEqual(scales.otherScaleCount(except: PageScales.key(document, 1), document), 0)
    }

    func test_remapMovesTypedAndFoundAndDropsWhatTheMapLeavesOut() throws {
        let found = MeasureScale(1, .millimetre, 100, .millimetre)
        let document = try writtenOn(pages: 3, page: 2, found)
        let keys = (0..<3).map { PageScales.key(document, $0) }
        let scales = PageScales(.actual)
        scales.set(keys[0], typed)
        scales.set(keys[1], typed)
        XCTAssertEqual(scales.scale(document, 2), found)

        scales.remap([keys[0]: 70, keys[2]: keys[1]])

        // The typed scale of the page left out of the map is gone; the found one moved to another page's number.
        XCTAssertEqual(scales.scale(document, 0), .actual)
        XCTAssertEqual(scales.scale(document, 1), found)
        scales.remap([70: keys[0]])
        XCTAssertEqual(scales.scale(document, 0), typed)
    }

    func test_pruneDropsTypedScalesOfPagesThatAreGone() throws {
        let document = try PdfDocument.open(Pdfs.text(2))
        let scales = PageScales(start)
        scales.set(PageScales.key(document, 0), typed)
        scales.set(99999, typed)

        scales.prune(document)

        XCTAssertEqual(scales.otherScaleCount(except: -1, document), 1)
    }
}
