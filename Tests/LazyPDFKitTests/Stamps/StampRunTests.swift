import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/StampRunTests.cs: the same cases. The PdfPig line of
// RemovingAfterReopeningLeavesTheCleanFile (the text of the clean file) has no twin.

final class StampRunTests: XCTestCase {
    private func names(_ document: PdfDocument, _ page: Int, _ category: String) -> String {
        (document.dict(document.pages[page].resources, category)?.entries ?? []).map { $0.key }.joined(separator: ",")
    }

    func test_runsGetIncreasingIdsAndAreListed() throws {
        let document = try StampKit.doc(3)
        let stamper = PdfStamper(document)
        let mark = try stamper.addWatermark(WatermarkSpec(text: "ONE", pages: [0, 1]))
        let ground = try stamper.addBackground(BackgroundSpec(color: .gray(0.9)))
        let notes = try stamper.addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", "{page}", "")))
        XCTAssertEqual([mark.id, ground.id, notes.id], [1, 2, 3])

        let all = stamper.list()
        XCTAssertEqual(all.map { $0.kind }, [.watermark, .background, .headerFooter])
        XCTAssertEqual(all[0].pages, [0, 1])
        XCTAssertEqual(all[2].pages, [0, 1, 2])
        XCTAssertEqual(stamper.list(document.pages[2]).map { $0.id }, [2, 3])
        XCTAssertEqual(all[2].label, "{page}")
    }

    func test_aRunSurvivesSavingAndIsFoundAgain() throws {
        let document = try StampKit.doc(2)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "KEEP"))
        let rewritten = try PdfDocument.open(try StampKit.rewrite(document))
        XCTAssertEqual(try StampKit.single(PdfStamper(rewritten).list()).id, 1)
        let incremental = try PdfDocument.open(try document.saveIncremental())
        let stamper = PdfStamper(incremental)
        XCTAssertEqual(try StampKit.single(stamper.list()).id, 1)
        XCTAssertEqual(try stamper.addWatermark(WatermarkSpec(text: "NEXT")).id, 2)
    }

    func test_removingARunRestoresThePage() throws {
        let document = try StampKit.doc(2)
        let before = StampKit.latin(document, 0)
        let stamper = PdfStamper(document)
        let run = try stamper.addWatermark(WatermarkSpec(text: "GONE", opacity: 0.5, layerName: "Mark"))
        try stamper.addWatermark(WatermarkSpec(text: "STAYS", pages: [1]))

        XCTAssertEqual(stamper.remove(run.id), 2)
        XCTAssertEqual(StampKit.latin(document, 0), before)
        XCTAssertEqual(names(document, 0, "ExtGState"), "")
        XCTAssertEqual(names(document, 0, "Properties"), "")
        XCTAssertEqual(names(document, 0, "Font"), "F1")
        XCTAssertNil(document.dict(document.catalog, "OCProperties"))
        XCTAssertEqual(StampKit.text(StampKit.glyphs(document, 1)), "STAYS")
        XCTAssertEqual(stamper.remove(run.id), 0)
    }

    func test_removingTheLastFrontStampTakesTheWrapperToo() throws {
        let document = try StampKit.doc(1)
        let stamper = PdfStamper(document)
        let run = try stamper.addWatermark(WatermarkSpec(text: "WRAP"))
        XCTAssertEqual(try StampKit.contentStreams(document, 0).count, 4)
        stamper.remove(run.id)
        XCTAssertEqual(try StampKit.contentStreams(document, 0).count, 1)
        XCTAssertEqual(StampKit.latin(document, 0), "BT /F1 12 Tf 50 50 Td (1) Tj ET")
    }

    func test_frontStampsShareOneWrapper() throws {
        let document = try StampKit.doc(1)
        let stamper = PdfStamper(document)
        let a = try stamper.addWatermark(WatermarkSpec(text: "A"))
        let b = try stamper.addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("h", "", "")))
        try stamper.addBackground(BackgroundSpec(color: .black))
        XCTAssertEqual(try StampKit.contentStreams(document, 0).count, 1 + 2 + 2 + 1)

        stamper.remove(a.id)
        XCTAssertEqual(try StampKit.contentStreams(document, 0).count, 1 + 2 + 1 + 1)
        stamper.remove(b.id)
        XCTAssertEqual(try StampKit.contentStreams(document, 0).count, 2)
        XCTAssertEqual(stamper.removeAll(), 1)
        XCTAssertEqual(try StampKit.contentStreams(document, 0).count, 1)
    }

    func test_updateReplacesTheRunUnderTheSameId() throws {
        let document = try StampKit.doc(3)
        let stamper = PdfStamper(document)
        let run = try stamper.addWatermark(WatermarkSpec(text: "OLD", opacity: 0.2))
        let updated = try stamper.update(run.id, WatermarkSpec(text: "NEW", opacity: 0.8, pages: [1]))

        XCTAssertEqual(updated.id, run.id)
        let info = try StampKit.single(stamper.list())
        XCTAssertEqual(info.label, "NEW")
        XCTAssertEqual(info.pages, [1])
        XCTAssertTrue(StampKit.glyphs(document, 0).isEmpty)
        XCTAssertEqual(StampKit.text(StampKit.glyphs(document, 1)), "NEW")
        XCTAssertEqual(names(document, 2, "ExtGState"), "")
        let state = try XCTUnwrap(document.dict(document.dict(document.pages[1].resources, "ExtGState"), "LPS1_G"))
        XCTAssertEqual(document.number(state, "ca"), 0.8)
    }

    func test_updateOfAnUnknownIdAddsTheRun() throws {
        let document = try StampKit.doc(1)
        let stamper = PdfStamper(document)
        try stamper.update(7, HeaderFooterSpec(header: HeaderFooterBand("", "x", "")))
        XCTAssertEqual(try StampKit.single(stamper.list()).id, 7)
    }

    func test_removingAfterReopeningLeavesTheCleanFile() throws {
        let document = try StampKit.doc(2)
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "TEMP", layerName: "L"))
        try PdfStamper(document).addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", "{page}", "")))
        let reopened = try PdfDocument.open(try StampKit.rewrite(document))
        let stamper = PdfStamper(reopened)

        XCTAssertEqual(stamper.removeAll(), 2)
        XCTAssertTrue(stamper.list().isEmpty)
        let clean = try StampKit.rewrite(reopened)
        let again = try PdfDocument.open(clean)
        XCTAssertTrue(StampKit.glyphs(again, 0).isEmpty)
        XCTAssertNil(again.dict(again.catalog, "OCProperties"))
    }

    func test_aRunOnPagesWithSharedResourcesWorks() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 300] /Resources 7 0 R>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>")
        pdf.stream(5, "", "BT /F1 12 Tf 50 50 Td (a) Tj ET")
        pdf.stream(6, "", "BT /F1 12 Tf 50 50 Td (b) Tj ET")
        pdf.obj(7, "<</Font <</F1 8 0 R>>>>")
        pdf.obj(8, ContentTestPdf.helvetica)
        let document = try PdfDocument.open(pdf.finish())
        let stamper = PdfStamper(document)
        let run = try stamper.addWatermark(WatermarkSpec(text: "SHARED"))
        XCTAssertEqual(StampKit.text(StampKit.glyphs(document, 1)), "SHARED")
        stamper.remove(run.id)
        XCTAssertEqual(names(document, 0, "Font"), "F1")
        XCTAssertTrue(StampKit.glyphs(document, 0).isEmpty)
    }

    func test_aPageWithoutContentsOrWithAnArrayTakesStamps() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 300]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents [5 0 R 6 0 R]>>")
        pdf.stream(5, "", "q 1 0 0 1 0 0 cm")
        pdf.stream(6, "", "0 0 10 10 re f")
        let document = try PdfDocument.open(pdf.finish())
        try PdfStamper(document).addWatermark(WatermarkSpec(text: "BOTH"))
        XCTAssertEqual(StampKit.text(StampKit.glyphs(document, 0)), "BOTH")
        XCTAssertEqual(StampKit.text(StampKit.glyphs(document, 1)), "BOTH")
        let reopened = try PdfDocument.open(try StampKit.rewrite(document))
        XCTAssertEqual(PdfStamper(reopened).list()[0].pages.count, 2)
    }
}
