import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/WatermarkTests.cs: the same cases. The PdfPig lines (the text and the picture
// read by a second reader) have no twin. NeitherTextNorImageIsRefused is a precondition here and cannot be caught. The
// Turkish text is the letters of the synthetic font, without ı, which it draws as ğ.

final class WatermarkTests: XCTestCase {
    private let jpeg = StampKit.jpeg

    private func helveticaBold(_ document: PdfDocument, _ text: String) throws -> PdfDrawFont {
        try XCTUnwrap(try PdfFontEmbedder(document).add("Helvetica", .bold, [text]))
    }

    func test_textWatermarkIsPageContentAndReopens() throws {
        let document = try StampKit.doc(2)
        let run = try PdfStamper(document).addWatermark(WatermarkSpec(text: "CONFIDENTIAL"))
        XCTAssertEqual(run.pages, 2)
        let file = try StampKit.rewrite(document)

        let reopened = try PdfDocument.open(file)
        XCTAssertEqual(StampKit.text(StampKit.glyphs(reopened, 1)), "CONFIDENTIAL")
        let info = try StampKit.single(PdfStamper(reopened).list())
        XCTAssertEqual(info.kind, .watermark)
        XCTAssertEqual(info.label, "CONFIDENTIAL")
        XCTAssertFalse(info.behind)
    }

    func test_theTextSpansTheScaleOfThePageWidth() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "WIDTH", scale: 0.5))
        let glyphs = StampKit.glyphs(document, 0)
        let font = try helveticaBold(document, "WIDTH")
        XCTAssertEqual(font.width("WIDTH", glyphs[0].size), 100, accuracy: 5e-4)
        XCTAssertEqual(glyphs[glyphs.count - 1].x - glyphs[0].x, font.width("WIDT", glyphs[0].size), accuracy: 5e-4)
    }

    func test_aCentredWatermarkIsCentredOnThePage() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "MID", scale: 0.4))
        let glyphs = StampKit.glyphs(document, 0)
        let font = try helveticaBold(document, "MID")
        let size = glyphs[0].size
        XCTAssertEqual(glyphs[0].x, 100 - font.width("MID", size) / 2, accuracy: 5e-4)
        let middle = glyphs[0].y - (font.ascent + font.descent) / 2 * size
        XCTAssertEqual(middle, 150, accuracy: 5e-4)
    }

    func test_rotationTurnsTheTextCounterClockwise() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "TILT", rotation: 90))
        let glyph = StampKit.glyphs(document, 0)[0]
        XCTAssertEqual(glyph.dirX, 0, accuracy: 5e-7)
        XCTAssertEqual(glyph.dirY, -1, accuracy: 5e-7)
    }

    func test_aRotatedPageStillShowsTheWatermarkAsAskedForOnScreen() throws {
        let document = try StampKit.pages([(keys: "/Rotate 90", content: "BT /F1 12 Tf 50 50 Td (r) Tj ET")])
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "SIDE", rotation: 0))
        let glyphs = StampKit.glyphs(document, 0)
        for g in glyphs {
            XCTAssertEqual(g.dirX, 1, accuracy: 5e-7)
            XCTAssertEqual(g.dirY, 0, accuracy: 5e-7)
        }
        let font = try helveticaBold(document, "SIDE")
        XCTAssertEqual(glyphs[0].x, 150 - font.width("SIDE", glyphs[0].size) / 2, accuracy: 5e-4)
        XCTAssertEqual(font.width("SIDE", glyphs[0].size), 0.6 * 300, accuracy: 5e-4)
    }

    func test_opacityIsAnExtGState() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "FADE", opacity: 0.25))
        for g in StampKit.glyphs(document, 0) { XCTAssertEqual(g.alpha, 0.25, accuracy: 5e-7) }
        let state = try XCTUnwrap(document.dict(document.dict(document.pages[0].resources, "ExtGState"), "LPS1_G"))
        XCTAssertEqual(document.number(state, "ca"), 0.25)
        XCTAssertEqual(document.number(state, "CA"), 0.25)
    }

    func test_fullOpacityAddsNoGraphicsState() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "SOLID", opacity: 1))
        XCTAssertNil(document.dict(document.pages[0].resources, "ExtGState"))
    }

    func test_behindComesBeforeThePageAndInFrontAfterIt() throws {
        let back = try StampKit.doc(1)
        try PdfStamper(back).addWatermark(WatermarkSpec(text: "UNDER", behind: true))
        let behind = StampKit.latin(back, 0)
        XCTAssertTrue(behind.hasPrefix("q\n"))
        XCTAssertTrue(try XCTUnwrap(behind.range(of: "/Artifact")).lowerBound < XCTUnwrap(behind.range(of: "(1)")).lowerBound)

        let front = try StampKit.doc(1)
        try PdfStamper(front).addWatermark(WatermarkSpec(text: "OVER"))
        let text = StampKit.latin(front, 0)
        XCTAssertTrue(try XCTUnwrap(text.range(of: "(1)")).lowerBound < XCTUnwrap(text.range(of: "/Artifact")).lowerBound)
    }

    func test_onlyTheListedPagesGetIt() throws {
        let document = try StampKit.doc(4)
        let run = try PdfStamper(document).addWatermark(WatermarkSpec(text: "SOME", pages: [2, 0, 9, -1, 2]))
        XCTAssertEqual(run.pages, 2)
        let info = try StampKit.single(PdfStamper(document).list())
        XCTAssertEqual(info.pages, [0, 2])
        XCTAssertTrue(StampKit.glyphs(document, 1).isEmpty)
        XCTAssertEqual(StampKit.glyphs(document, 2).count, 4)
    }

    func test_anImageWatermarkIsScaledAndKeepsItsProportions() throws {
        let document = try StampKit.doc(1)
        let image = try XCTUnwrap(try PdfImageWriter.addJpeg(document, jpeg))
        try PdfStamper(document).addWatermark(WatermarkSpec(image: image, scale: 0.5))
        let file = try StampKit.rewrite(document)

        let reopened = try PdfDocument.open(file)
        let placed = try StampKit.single(ContentTestPdf.run(reopened).images)
        XCTAssertEqual(placed.bounds.width, 100, accuracy: 5e-4)
        XCTAssertEqual(placed.bounds.height, 75, accuracy: 5e-4)
        XCTAssertEqual(placed.bounds.left, 50, accuracy: 5e-4)
    }

    func test_anchorAndOffsetMoveItInDisplayPoints() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "TL", scale: 0.2, anchor: .topLeft, offsetX: 10, offsetY: 20))
        let glyphs = StampKit.glyphs(document, 0)
        XCTAssertEqual(glyphs[0].x, 10, accuracy: 5e-4)
        let font = try helveticaBold(document, "TL")
        XCTAssertEqual(glyphs[0].y, 20 + font.ascent * glyphs[0].size, accuracy: 5e-4)
    }

    func test_multipleLinesAreCentredOnEachOther() throws {
        let document = try StampKit.doc(1)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "LONGER LINE\nAB"))
        let glyphs = StampKit.glyphs(document, 0)
        let first = try XCTUnwrap(glyphs.first { $0.text == "L" })
        let second = try XCTUnwrap(glyphs.first { $0.text == "A" })
        XCTAssertTrue(second.y > first.y)
        XCTAssertTrue(second.x > first.x)
    }

    private final class LayerVisitor: ContentVisitor {
        var seen: [PdfDictionary?] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            if context.marked.contains(where: { $0.tag == "Artifact" }) { seen.append(context.optionalContent) }
        }
    }

    func test_aLayerMakesItOptionalContent() throws {
        let document = try StampKit.doc(2)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "LAYERED", layerName: "Watermark"))
        let file = try StampKit.rewrite(document)
        let reopened = try PdfDocument.open(file)

        let properties = try XCTUnwrap(reopened.dict(reopened.catalog, "OCProperties"))
        let groups = try XCTUnwrap(reopened.array(properties, "OCGs"))
        let group = try XCTUnwrap(reopened.resolve(try StampKit.single(groups.items)) as? PdfDictionary)
        XCTAssertEqual(reopened.name(group, "Type"), "OCG")
        XCTAssertEqual(try XCTUnwrap(reopened.array(reopened.dict(properties, "D"), "Order")).items.count, 1)
        XCTAssertTrue(StampKit.latin(reopened, 1).contains("/OC /LPS1_P BDC"))
        assertSame(group, reopened.dict(reopened.dict(reopened.pages[1].resources, "Properties"), "LPS1_P"))

        let visitor = LayerVisitor()
        ContentInterpreter(reopened).run(reopened.pages[0], visitor)
        XCTAssertEqual(visitor.seen.count, 7)
        for o in visitor.seen { assertSame(group, o) }
    }

    func test_turkishTextEmbedsAFontAndReadsBack() throws {
        let document = try StampKit.doc(1)
        let text = "ğİ AB"
        let run = try PdfStamper(document, try ArialSource()).addWatermark(WatermarkSpec(text: text))
        XCTAssertTrue(run.missing.isEmpty)
        let file = try StampKit.rewrite(document)
        let reopened = try PdfDocument.open(file)
        XCTAssertEqual(StampKit.text(StampKit.glyphs(reopened, 0)), text)
    }

    func test_withoutAFontForTheTextNothingIsChanged() throws {
        let document = try StampKit.doc(1)
        XCTAssertThrowsError(try PdfStamper(document).addWatermark(WatermarkSpec(text: "Şişli"))) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, StampsText.noFont)
        }
        XCTAssertTrue(PdfStamper(document).list().isEmpty)
        XCTAssertTrue(StampKit.glyphs(document, 0).isEmpty)
    }

    func test_watermarksOnAnIncrementalSaveReopenToo() throws {
        let document = try StampKit.doc(2)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "UPDATE", rotation: 30))
        let file = try document.saveIncremental()
        let reopened = try PdfDocument.open(file)
        XCTAssertEqual(try StampKit.single(PdfStamper(reopened).list()).pages.count, 2)
    }
}
