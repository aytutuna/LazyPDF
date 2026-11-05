import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/TextMarkupTests.cs: the same cases. PdfPigReadsTheHighlight has no twin
// (PdfPig).

final class TextMarkupTests: XCTestCase {
    private let line = [MarkupQuad.fromRect(PdfRect(100, 500, 300, 514))]
    private let info = AnnotationInfo(author: "Ayşe", contents: "check this", subject: "Review", date: DateTimeOffset(2026, 3, 4, 10, 0, 0))

    func test_highlightMultipliesInItsOwnAppearance() throws {
        let document = try AnnotationFixtures.blank()
        let writer = PdfAnnotationWriter(document)
        let highlight = try writer.addTextMarkup(document.pages[0], .highlight, line, info: info, style: AnnotationStyle(opacity: 0.5))

        XCTAssertEqual(highlight.subtype, "Highlight")
        XCTAssertEqual(highlight.opacity, 0.5)
        XCTAssertEqual(highlight.color, [1, 1, 0])
        let form = try AnnotationFixtures.normal(document, highlight)
        XCTAssertEqual(document.name(form.dictionary, "Subtype"), "Form")
        let state = try XCTUnwrap(document.dict(document.dict(document.dict(form.dictionary, "Resources"), "ExtGState"), "GS1"))
        XCTAssertEqual(document.name(state, "BM"), "Multiply")
        XCTAssertEqual(document.number(state, "ca"), 0.5)
        let ops = try AnnotationFixtures.appearance(document, highlight)
        XCTAssertTrue(AnnotationFixtures.operators(ops).contains("gs"))
        XCTAssertTrue(AnnotationFixtures.operators(ops).contains("f"))
    }

    func test_boxOfTheAppearanceIsTheRectangle() throws {
        let document = try AnnotationFixtures.blank()
        let writer = PdfAnnotationWriter(document)
        let highlight = try writer.addTextMarkup(document.pages[0], .highlight, line)
        let array = try XCTUnwrap(document.array(try AnnotationFixtures.normal(document, highlight).dictionary, "BBox"))
        let box = array.items.map { ($0 as? PdfNumber)?.value ?? -1 }
        XCTAssertEqual(box, [0, 0, highlight.rect.width, highlight.rect.height])
        XCTAssertEqual(highlight.rect, PdfRect(99, 499, 301, 515))
    }

    func test_linesAreStrokedInTheAnnotationColour() throws {
        for kind in [AnnotationType.underline, .strikeOut, .squiggly] {
            let document = try AnnotationFixtures.blank()
            let writer = PdfAnnotationWriter(document)
            let markup = try writer.addTextMarkup(document.pages[0], kind, [line[0], MarkupQuad.fromRect(PdfRect(100, 480, 200, 494))], info: info, style: AnnotationStyle(color: [0, 0.5, 1]))
            let ops = try AnnotationFixtures.appearance(document, markup)
            XCTAssertEqual(ops.filter { $0.operator == "S" }.count, 2, "\(kind)")
            XCTAssertTrue(ops.contains { $0.operator == "RG" && $0.number(2) == 1 }, "\(kind)")
            XCTAssertEqual(markup.quads.count, 2, "\(kind)")
        }
    }

    func test_squigglyZigzagsAlongTheBaseline() throws {
        let document = try AnnotationFixtures.blank()
        let squiggly = try PdfAnnotationWriter(document).addTextMarkup(document.pages[0], .squiggly, line)
        let points = try AnnotationFixtures.appearance(document, squiggly).filter { $0.operator == "m" || $0.operator == "l" }.map { $0.number(1) ?? 0 }
        XCTAssertTrue(points.count > 50)
        XCTAssertEqual(points.prefix(2).map { ($0 * 10).rounded(.toNearestOrEven) / 10 }, [1.4, 2.8])
    }

    func test_keepsAuthorDatesAndName() throws {
        let document = try AnnotationFixtures.blank()
        let highlight = try PdfAnnotationWriter(document).addTextMarkup(document.pages[0], .highlight, line, info: info)
        let reopened = try AnnotationFixtures.reopen(document)
        let all = PdfAnnotations.read(reopened, document.pages[0])
        XCTAssertEqual(all.count, 1)
        let reread = all[0]
        XCTAssertEqual(reread.title, "Ayşe")
        XCTAssertEqual(reread.contents, "check this")
        XCTAssertEqual(reread.subject, "Review")
        XCTAssertEqual(reread.created, info.date)
        XCTAssertEqual(reread.modified, info.date)
        XCTAssertFalse((reread.name ?? "").isEmpty)
        XCTAssertEqual(reread.flags, .print)
        XCTAssertEqual(reread.name, highlight.name)
        XCTAssertTrue(reread.hasAppearance)
    }

    func test_refusesOtherKindsAndNoQuads() throws {
        let document = try AnnotationFixtures.blank()
        let writer = PdfAnnotationWriter(document)
        XCTAssertThrowsError(try writer.addTextMarkup(document.pages[0], .ink, line)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try writer.addTextMarkup(document.pages[0], .highlight, [])) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_aQuadTooFarOutToInflateHasNoArea() throws {
        let document = try AnnotationFixtures.blank()
        let far = [MarkupQuad.fromRect(PdfRect(1e18, 500, 1e18, 514))]
        XCTAssertThrowsError(try PdfAnnotationWriter(document).addTextMarkup(document.pages[0], .highlight, far)) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_appendsToAnIndirectAnnotsArray() throws {
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, "[]") }, pageEntries: "/Annots 20 0 R")
        try PdfAnnotationWriter(document).addTextMarkup(document.pages[0], .highlight, line)
        XCTAssertEqual((document.get(20) as? PdfArray)?.items.count, 1)
    }
}
