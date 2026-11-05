import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/FlattenTests.cs: the same cases. PdfPig no longer reads the saved file,
// so PageContentIsWrappedSoItsStateCannotLeakIn and FlattenedFreeTextIsTextOnThePage read its text and annotations with
// our own interpreter and reader instead.

final class FlattenTests: XCTestCase {
    private let line = [MarkupQuad.fromRect(PdfRect(100, 500, 300, 514))]

    private func run(_ document: PdfDocument, _ page: Int = 0) -> Recorder {
        let recorder = Recorder()
        ContentInterpreter(document).run(document.pages[page], recorder)
        return recorder
    }

    func test_appearancesLandInThePageWhereTheAnnotationWas() throws {
        let document = try AnnotationFixtures.blank()
        let writer = PdfAnnotationWriter(document)
        try writer.addTextMarkup(document.pages[0], .highlight, line)
        try writer.addSquare(document.pages[0], PdfRect(200, 200, 300, 260), style: AnnotationStyle(width: 4))

        XCTAssertEqual(try PdfAnnotationFlattener.flatten(document, document.pages[0]), 2)
        XCTAssertTrue(PdfAnnotations.read(document, document.pages[0]).isEmpty)
        let paths = run(document).paths
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0].path.bounds, PdfRect(100, 500, 300, 514))
        XCTAssertEqual(paths[1].path.bounds, PdfRect(202, 202, 298, 258))
        XCTAssertEqual(paths[0].state.blendMode, "Multiply")
        try AnnotationFixtures.reopen(document)
    }

    func test_pageContentIsWrappedSoItsStateCannotLeakIn() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>")
        pdf.stream(4, "", "0.5 0 0 0.5 0 0 cm 1 0 0 rg q BT /F1 20 Tf 100 100 Td (Page) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        let document = try PdfDocument.open(pdf.finish())
        try PdfAnnotationWriter(document).addSquare(document.pages[0], PdfRect(200, 200, 300, 260), style: AnnotationStyle(width: 4))

        try PdfAnnotationFlattener.flatten(document, document.pages[0])
        let recorder = run(document)
        XCTAssertEqual(recorder.text, "Page")
        XCTAssertEqual(recorder.paths.count, 1)
        XCTAssertEqual(try XCTUnwrap(recorder.paths.first).path.bounds, PdfRect(202, 202, 298, 258))
        XCTAssertNotNil(document.dict(document.dict(document.pages[0].dictionary, "Resources"), "Font"))
        XCTAssertNil(document.dict(document.dict(document.get(2) as? PdfDictionary, "Resources"), "XObject"))
        let reopened = try AnnotationFixtures.reopen(document)
        XCTAssertEqual(run(reopened).text, "Page")
        XCTAssertTrue(PdfAnnotations.read(reopened, reopened.pages[0]).isEmpty)
    }

    func test_flattenedFreeTextIsTextOnThePage() throws {
        let document = try AnnotationFixtures.blank()
        try PdfAnnotationWriter(document).addFreeText(document.pages[0], PdfRect(100, 600, 300, 640), "Flat words")
        try PdfAnnotationFlattener.flattenAll(document)
        XCTAssertEqual(run(document).text, "Flat words")
        XCTAssertEqual(run(try AnnotationFixtures.reopen(document)).text, "Flat words")
    }

    func test_hiddenAndNoViewAnnotationsStayAsTheyAre() throws {
        let document = try AnnotationFixtures.blank()
        let writer = PdfAnnotationWriter(document)
        let page = document.pages[0]
        try writer.addSquare(page, PdfRect(10, 10, 50, 50), info: AnnotationInfo(flags: .hidden))
        try writer.addSquare(page, PdfRect(60, 10, 100, 50), info: AnnotationInfo(flags: [.noView, .print]))
        try writer.addSquare(page, PdfRect(110, 10, 150, 50))
        XCTAssertEqual(try PdfAnnotationFlattener.flatten(document, page), 1)
        XCTAssertEqual(PdfAnnotations.read(document, page).count, 2)
    }

    func test_byTypeLeavesTheOthers() throws {
        let document = try AnnotationFixtures.blank()
        let writer = PdfAnnotationWriter(document)
        let page = document.pages[0]
        try writer.addTextMarkup(page, .highlight, line)
        try writer.addSquare(page, PdfRect(10, 10, 50, 50))
        try writer.addCircle(page, PdfRect(60, 10, 100, 50))
        XCTAssertEqual(try PdfAnnotationFlattener.flatten(document, page, [.highlight, .circle]), 2)
        let rest = PdfAnnotations.read(document, page)
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest.first?.type, .square)
    }

    func test_allMeansWhatOnlyShowsSomething() throws {
        let document = try AnnotationFixtures.blank(1, { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /Link /Rect [0 0 50 50] /Border [0 0 1] /AP <</N 30 0 R>>>>")
            pdf.obj(21, "<</Type /Annot /Subtype /Widget /Rect [0 0 50 50] /AP <</N 30 0 R>>>>")
            pdf.obj(22, "<</Type /Annot /Subtype /FileAttachment /Rect [0 0 50 50] /AP <</N 30 0 R>>>>")
            pdf.obj(23, "<</Type /Annot /Subtype /Redact /Rect [0 0 50 50] /AP <</N 30 0 R>>>>")
            pdf.obj(24, "<</Type /Annot /Subtype /Stamp /Rect [0 0 50 50] /AP <</N 30 0 R>>>>")
            pdf.obj(25, "<</Type /Annot /Subtype /Watermark /Rect [0 0 50 50] /AP <</N 30 0 R>>>>")
            pdf.obj(26, "<</Type /Annot /Subtype /Square /Rect [0 0 50 50]>>")
            pdf.stream(30, "/BBox [0 0 50 50]", "0 0 50 50 re f")
        }, pageEntries: "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R 25 0 R 26 0 R]")
        XCTAssertEqual(try PdfAnnotationFlattener.flattenAll(document), 2)
        XCTAssertEqual(PdfAnnotations.read(document, document.pages[0]).map { $0.subtype }, ["Link", "Widget", "FileAttachment", "Redact", "Square"])
        XCTAssertEqual(try PdfAnnotationFlattener.flatten(document, document.pages[0], [.widget, .link]), 2)
        XCTAssertEqual(PdfAnnotations.read(document, document.pages[0]).count, 3)
    }

    func test_widgetsFlattenThroughTheirAppearanceState() throws {
        let document = try AnnotationFixtures.blank(1, { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /Widget /FT /Btn /Rect [10 10 30 30] /AS /Yes /AP <</N <</Yes 30 0 R /Off 31 0 R>>>>>>")
            pdf.obj(21, "<</Type /Annot /Subtype /Widget /FT /Btn /Rect [40 10 60 30] /AS /Off /AP <</N <</Yes 30 0 R>>>>>>")
            pdf.stream(30, "/BBox [0 0 20 20]", "0 0 20 20 re f")
            pdf.stream(31, "/BBox [0 0 20 20]", "")
        }, pageEntries: "/Annots [20 0 R 21 0 R]")
        XCTAssertEqual(try PdfAnnotationFlattener.flatten(document, document.pages[0], [.widget]), 1)
        let recorder = run(document)
        XCTAssertEqual(recorder.paths.count, 1)
        XCTAssertEqual(try XCTUnwrap(recorder.paths.first).path.bounds, PdfRect(10, 10, 30, 30))
        XCTAssertEqual(PdfAnnotations.read(document, document.pages[0]).count, 1)
    }

    func test_formMatrixAndBoxAreFittedToTheRectangle() throws {
        let document = try AnnotationFixtures.blank(1, { pdf in
            pdf.obj(20, "<</Type /Annot /Subtype /Stamp /Rect [100 100 300 150] /AP <</N 30 0 R>>>>")
            pdf.stream(30, "/Subtype /Form /BBox [0 0 10 20] /Matrix [0 1 -1 0 0 0]", "0 0 10 20 re f")
        }, pageEntries: "/Annots [20 0 R]")
        try PdfAnnotationFlattener.flattenAll(document)
        let recorder = run(document)
        XCTAssertEqual(recorder.paths.count, 1)
        let bounds = try XCTUnwrap(recorder.paths.first).path.bounds
        XCTAssertEqual(bounds.left, 100, accuracy: 5e-4)
        XCTAssertEqual(bounds.right, 300, accuracy: 5e-4)
        XCTAssertEqual(bounds.bottom, 100, accuracy: 5e-4)
        XCTAssertEqual(bounds.top, 150, accuracy: 5e-4)
    }

    func test_popupsAndRepliesGoWithTheirParent() throws {
        let document = try AnnotationFixtures.blank(1)
        let writer = PdfAnnotationWriter(document)
        let square = try writer.addSquare(document.pages[0], PdfRect(10, 10, 80, 80), info: AnnotationInfo(author: "A", contents: "box"))
        let reply = try PdfComments.reply(document, square, "re", "B", DateTimeOffset(2026, 1, 1, 0, 0, 0))
        try PdfComments.reply(document, reply, "re re", "C", DateTimeOffset(2026, 1, 2, 0, 0, 0))
        let keep = try writer.addCircle(document.pages[0], PdfRect(100, 10, 180, 80))
        XCTAssertEqual(try PdfAnnotationFlattener.flatten(document, document.pages[0], [.square]), 1)
        let rest = PdfAnnotations.read(document, document.pages[0])
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest.first?.name, keep.name)
        XCTAssertNil(document.get(try XCTUnwrap(square.reference).number))
    }

    func test_nothingToDoLeavesThePageUntouched() throws {
        let document = try AnnotationFixtures.blank()
        XCTAssertEqual(try PdfAnnotationFlattener.flattenAll(document), 0)
        XCTAssertNil(document.pages[0].dictionary["Contents"])
        let bytes = try document.saveIncremental()
        XCTAssertEqual(document.length, bytes.count)
    }

    func test_anAnnotationWithoutAnAppearanceStays() throws {
        let document = try AnnotationFixtures.blank(1, { $0.obj(20, "<</Type /Annot /Subtype /Square /Rect [0 0 50 50]>>") }, pageEntries: "/Annots [20 0 R]")
        XCTAssertEqual(try PdfAnnotationFlattener.flattenAll(document), 0)
        XCTAssertEqual(PdfAnnotations.read(document, document.pages[0]).count, 1)
    }
}
