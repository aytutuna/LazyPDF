import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/BackgroundTests.cs: the same cases. The PdfPig lines (the text and the picture
// read by a second reader) have no twin. ABackgroundNeedsAColourOrAnImage is a precondition here and cannot be caught.

final class BackgroundTests: XCTestCase {
    private let jpeg = StampKit.jpeg

    func test_aColourFillsThePageBehindTheContent() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addBackground(BackgroundSpec(color: StampColor(1, 1, 0.8)))
        let file = try StampKit.rewrite(document)

        let reopened = try PdfDocument.open(file)
        let recorder = ContentTestPdf.run(reopened)
        let filled = recorder.paths.filter { $0.path.fill }
        XCTAssertEqual(filled.count, 1)
        let (path, state) = try XCTUnwrap(filled.first)
        XCTAssertEqual(path.bounds, PdfRect(0, 0, 200, 300))
        XCTAssertEqual(state.fillColor.components, [1, 1, 0.8])
        XCTAssertTrue(StampKit.latin(reopened, 0).hasPrefix("q\n"))
        let info = try StampKit.single(PdfStamper(reopened).list())
        XCTAssertEqual(info.kind, .background)
        XCTAssertTrue(info.behind)
    }

    func test_coverFillsThePageAndClipsTheOverflow() throws {
        let document = try StampKit.doc(1)
        let image = try XCTUnwrap(try PdfImageWriter.addJpeg(document, jpeg))
        try PdfStamper(document).addBackground(BackgroundSpec(image: image, fit: .cover))
        let placed = try StampKit.single(ContentTestPdf.run(document).images)
        XCTAssertEqual(placed.bounds.height, 300, accuracy: 5e-4)
        XCTAssertEqual(placed.bounds.width, 400, accuracy: 5e-4)
        XCTAssertEqual(placed.bounds.left, -100, accuracy: 5e-4)
    }

    func test_containStaysInsideAndStretchChangesTheProportions() throws {
        let document = try StampKit.doc(2)
        let image = try XCTUnwrap(try PdfImageWriter.addJpeg(document, jpeg))
        let stamper = PdfStamper(document)
        try stamper.addBackground(BackgroundSpec(image: image, fit: .contain, pages: [0]))
        try stamper.addBackground(BackgroundSpec(image: image, fit: .stretch, pages: [1]))

        let contained = try StampKit.single(ContentTestPdf.run(document).images).bounds
        XCTAssertEqual(contained.width, 200)
        XCTAssertEqual(contained.height, 150)
        XCTAssertEqual(contained.left, 0)
        XCTAssertEqual(contained.bottom, 75)
        let stretched = Recorder()
        ContentInterpreter(document).run(document.pages[1], stretched)
        XCTAssertEqual(try StampKit.single(stretched.images).bounds, PdfRect(0, 0, 200, 300))
    }

    func test_colourAndImageTogetherAndTranslucent() throws {
        let document = try StampKit.doc(1)
        let image = try PdfImageWriter.addRgba(document, 2, 2, [UInt8](repeating: 0, count: 16))
        try PdfStamper(document).addBackground(BackgroundSpec(color: .gray(0.9), image: image, opacity: 0.5))
        let recorder = ContentTestPdf.run(document)
        XCTAssertEqual(recorder.paths.filter { $0.path.fill }.count, 1)
        XCTAssertEqual(recorder.images.count, 1)
        let state = try XCTUnwrap(document.dict(document.dict(document.pages[0].resources, "ExtGState"), "LPS1_G"))
        XCTAssertEqual(document.number(state, "ca"), 0.5)
    }

    func test_aRotatedPageIsCoveredAsItIsShown() throws {
        let document = try StampKit.pages([(keys: "/Rotate 90", content: "BT /F1 12 Tf 50 50 Td (r) Tj ET")])
        let image = try XCTUnwrap(try PdfImageWriter.addJpeg(document, jpeg))
        try PdfStamper(document).addBackground(BackgroundSpec(image: image, fit: .contain))
        let placed = try StampKit.single(ContentTestPdf.run(document).images)
        let shown = PageGeometry(document.pages[0]).toDisplay(placed.bounds)
        XCTAssertEqual(shown.width, 266.667, accuracy: 5e-4)
        XCTAssertEqual(shown.height, 200, accuracy: 5e-4)
        XCTAssertEqual(shown.x, 16.667, accuracy: 5e-4)
    }
}
