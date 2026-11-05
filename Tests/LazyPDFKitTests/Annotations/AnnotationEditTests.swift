import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/AnnotationEditTests.cs: the same cases.

final class AnnotationEditTests: XCTestCase {
    private let line = [MarkupQuad.fromRect(PdfRect(100, 500, 300, 514))]

    private func start() throws -> (document: PdfDocument, writer: PdfAnnotationWriter, page: PdfPage) {
        let document = try AnnotationFixtures.blank()
        return (document, PdfAnnotationWriter(document), document.pages[0])
    }

    func test_moveShiftsRectAndEveryPointKey() throws {
        let (document, writer, page) = try start()
        let ink = try writer.addInk(page, [[(100, 600), (120, 640)], [(200, 600), (220, 640)]])
        let moved = try writer.move(ink, 30, -10)
        XCTAssertEqual(moved.rect.left, ink.rect.left + 30)
        XCTAssertEqual(moved.rect.bottom, ink.rect.bottom - 10)
        XCTAssertEqual(moved.inkList[0], [130, 590, 150, 630])
        let shifted = try writer.move(try writer.addLine(page, (10, 10), (50, 60)), 5, 5)
        XCTAssertEqual(shifted.line, [15, 15, 55, 65])
        let markup = try writer.move(try writer.addTextMarkup(page, .highlight, line), 0, 100)
        XCTAssertEqual(markup.quads[0].y1, 614)
        XCTAssertEqual(markup.quads[0].y3, 600)
        try AnnotationFixtures.reopen(document)
    }

    func test_moveLeavesTheAppearanceStreamAlone() throws {
        let (document, writer, page) = try start()
        let square = try writer.addSquare(page, PdfRect(100, 600, 200, 650))
        let before = try AnnotationFixtures.normal(document, square)
        let moved = try writer.move(square, 40, 40)
        XCTAssertTrue(before === (try AnnotationFixtures.normal(document, moved)))
    }

    func test_resizeScalesPointsAndDrawsAgain() throws {
        let (document, writer, page) = try start()
        let polygon = try writer.addPolygon(page, [(100, 600), (200, 600), (150, 700)], style: AnnotationStyle(width: 2))
        let before = try AnnotationFixtures.normal(document, polygon)
        let bounds = polygon.rect
        let target = PdfRect(bounds.left, bounds.bottom, bounds.left + bounds.width * 2, bounds.bottom + bounds.height / 2)
        let resized = try writer.resize(polygon, target)
        XCTAssertEqual(resized.rect, target)
        XCTAssertEqual(resized.vertices[0], 102, accuracy: 5e-4)
        XCTAssertEqual(resized.vertices[2], 302, accuracy: 5e-4)
        XCTAssertFalse(before === (try AnnotationFixtures.normal(document, resized)))
        let box = try XCTUnwrap(document.array(try AnnotationFixtures.normal(document, resized).dictionary, "BBox"))
        XCTAssertEqual((box.items[2] as? PdfNumber)?.value ?? 0, target.width, accuracy: 5e-4)
    }

    func test_resizeRewrapsFreeText() throws {
        let (document, writer, page) = try start()
        let box = try writer.addFreeText(page, PdfRect(100, 500, 400, 600), "one two three four five six seven eight nine ten")
        func lines(_ a: PdfAnnotation) throws -> Int {
            let recorder = try AnnotationFixtures.draw(document, a)
            return Set(recorder.glyphs.map { ($0.bounds.bottom * 10).rounded(.toNearestOrEven) / 10 }).count
        }
        let wide = try lines(box)
        let narrow = try writer.resize(box, PdfRect(100, 500, 160, 600))
        XCTAssertTrue(try lines(narrow) > wide)
    }

    func test_colourChangeRedrawsTheAppearance() throws {
        let (document, writer, page) = try start()
        let highlight = try writer.addTextMarkup(page, .highlight, line)
        let green = try writer.setColor(highlight, [0, 1, 0])
        XCTAssertEqual(green.color, [0, 1, 0])
        XCTAssertTrue(try AnnotationFixtures.appearance(document, green).contains { $0.operator == "rg" && $0.number(1) == 1 && $0.number(0) == 0 })

        let square = try writer.addSquare(page, PdfRect(10, 10, 80, 80))
        let filled = try writer.setColor(square, [0, 0, 1], interior: [1, 0, 0])
        XCTAssertEqual(filled.interiorColor, [1, 0, 0])
        let painted = try AnnotationFixtures.appearance(document, filled)
        XCTAssertTrue(AnnotationFixtures.operators(painted).contains("B"))
        XCTAssertTrue(painted.contains { $0.operator == "RG" && $0.number(2) == 1 })

        let transparent = try writer.setOpacity(green, 0.25)
        XCTAssertEqual(transparent.opacity, 0.25)
        XCTAssertTrue(AnnotationFixtures.operators(try AnnotationFixtures.appearance(document, transparent)).contains("gs"))
    }

    func test_contentsChangeAndFreeTextIsDrawnAgain() throws {
        let (document, writer, page) = try start()
        let note = try writer.addNote(page, PdfRect(10, 700, 30, 720), AnnotationInfo(author: "A", contents: "first"))
        let date = DateTimeOffset(2026, 5, 6, 7, 8, 9)
        let changed = try writer.setContents(note, "second", date: date)
        XCTAssertEqual(changed.contents, "second")
        XCTAssertEqual(changed.modified, date)

        let rich = "<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>old words</p></body>"
        let box = try writer.addFreeText(page, PdfRect(100, 600, 300, 640), "", font: FreeTextStyle(richText: rich))
        let edited = try writer.setContents(box, "new words")
        XCTAssertNil(edited.richText)
        XCTAssertEqual(try AnnotationFixtures.draw(document, edited).text, "new words")
    }

    func test_freeTextStyleChangeKeepsTheText() throws {
        let (document, writer, page) = try start()
        let box = try writer.addFreeText(page, PdfRect(100, 600, 300, 640), "styled")
        let bigger = try writer.setFreeTextStyle(box, FreeTextStyle(family: "Courier New", size: 20, font: .bold, textColor: [1, 0, 0], alignment: 1))
        XCTAssertEqual(bigger.defaultAppearance, "/CoBo 20 Tf 1 0 0 rg")
        XCTAssertEqual(bigger.alignment, 1)
        let recorder = try AnnotationFixtures.draw(document, bigger)
        XCTAssertEqual(recorder.text, "styled")
        XCTAssertEqual(recorder.glyphs[0].font.baseFont, "Courier-Bold")
        let square = try writer.addSquare(page, PdfRect(1, 1, 50, 50))
        XCTAssertThrowsError(try writer.setFreeTextStyle(square, FreeTextStyle())) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_deleteTakesPopupAndRepliesWithIt() throws {
        let document = try AnnotationFixtures.blank(1, { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (parent) /Popup 21 0 R /NM (p)>>")
            pdf.obj(21, "<</Type /Annot /Subtype /Popup /Rect [40 10 140 60] /Parent 20 0 R>>")
            pdf.obj(22, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /IRT 20 0 R /RT /R /Contents (reply)>>")
            pdf.obj(23, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /IRT 22 0 R /Contents (reply to reply)>>")
            pdf.obj(24, "<</Type /Annot /Subtype /Text /Rect [90 90 100 100] /Contents (other)>>")
        }, pageEntries: "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R]")
        let page = document.pages[0]
        let writer = PdfAnnotationWriter(document)
        let parent = PdfAnnotations.read(document, page)[0]
        XCTAssertTrue(writer.delete(parent))
        let rest = PdfAnnotations.read(document, page)
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest.first?.contents, "other")
        for number in [20, 21, 22, 23] { XCTAssertNil(document.get(number)) }
        XCTAssertNotNil(document.get(24))
        XCTAssertFalse(writer.delete(parent))
        try AnnotationFixtures.reopen(document)
    }

    func test_deleteWorksOnAnAnnotationWrittenDirectlyInTheArray() throws {
        let document = try AnnotationFixtures.blank(1, pageEntries: "/Annots [<</Subtype /Square /Rect [1 1 20 20]>>]")
        let writer = PdfAnnotationWriter(document)
        let all = PdfAnnotations.read(document, document.pages[0])
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(writer.delete(all[0]))
        XCTAssertTrue(PdfAnnotations.read(document, document.pages[0]).isEmpty)
    }

    func test_regenerateGivesAForeignAnnotationAnAppearance() throws {
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, "<</Type /Annot /Subtype /Square /Rect [100 100 200 150] /C [0 1 0] /BS <</W 3>>>>") }, pageEntries: "/Annots [20 0 R]")
        let writer = PdfAnnotationWriter(document)
        let square = try XCTUnwrap(PdfAnnotations.read(document, document.pages[0]).first)
        XCTAssertFalse(square.hasAppearance)
        XCTAssertTrue(try writer.regenerate(square))
        XCTAssertEqual(PdfAnnotations.read(document, document.pages[0]).first?.hasAppearance, true)
        let widget = PdfDictionary()
        widget["Subtype"] = PdfName("Widget")
        XCTAssertFalse(try writer.regenerate(try XCTUnwrap(PdfAnnotations.parse(document, widget, nil))))
    }

    func test_unknownKeysSurviveEdits() throws {
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, "<</Type /Annot /Subtype /Square /Rect [100 100 200 150] /C [0 1 0] /Custom (keep) /Foo 42>>") }, pageEntries: "/Annots [20 0 R]")
        let writer = PdfAnnotationWriter(document)
        let square = try XCTUnwrap(PdfAnnotations.read(document, document.pages[0]).first)
        try writer.setColor(try writer.move(square, 5, 5), [1, 0, 0])
        let reopened = try AnnotationFixtures.reopen(document)
        let kept = try XCTUnwrap(PdfAnnotations.read(reopened, reopened.pages[0]).first)
        XCTAssertEqual(reopened.integer(kept.dictionary, "Foo"), 42)
        XCTAssertTrue(kept.dictionary.containsKey("Custom"))
    }

    func test_anEditThatCannotBeDrawnLeavesTheAnnotationAsItWas() throws {
        let document = try AnnotationFixtures.blank(1, { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /FreeText /Rect [100 100 300 150] /C [0 1 0] /Contents <FEFF015F011F> /DA (/Helv 12 Tf 0 g) /Vertices [1 2 3 4] /RC (<body/>)>>")
        }, pageEntries: "/Annots [20 0 R]")
        let writer = PdfAnnotationWriter(document)
        let box = try XCTUnwrap(PdfAnnotations.read(document, document.pages[0]).first)
        func assertNoFont(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertTrue($0 is InvalidOperationException, file: file, line: line) }
        }
        assertNoFont { try writer.setColor(box, [1, 0, 0]) }
        assertNoFont { try writer.resize(box, PdfRect(0, 0, 500, 500)) }
        assertNoFont { try writer.setContents(box, "ığ") }
        let after = try XCTUnwrap(PdfAnnotations.read(document, document.pages[0]).first)
        XCTAssertEqual(after.color, [0, 1, 0])
        XCTAssertEqual(after.rect, box.rect)
        XCTAssertEqual(after.vertices, [1, 2, 3, 4])
        XCTAssertEqual(after.richText, "<body/>")
        XCTAssertEqual(after.contents, "şğ")
        XCTAssertFalse(after.hasAppearance)
    }
}
