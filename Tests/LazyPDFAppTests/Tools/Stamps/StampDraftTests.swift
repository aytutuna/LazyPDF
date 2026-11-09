import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/stamps/StampDraftTests.cs: a stamp from the form to the file: written by the engine,
// committed through the tab, found again, updated and taken off.

@MainActor
final class StampDraftTests: XCTestCase {
    private func open(_ pages: Int) throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(Pdfs.text(pages)), renderer: FakeRenderer(), url: nil, title: "a.pdf")
    }

    private func stamps(_ tab: DocumentTab) -> [StampInfo] {
        PdfStamper(tab.document).list()
    }

    private func mark(_ text: String, pages: [Int]? = nil) -> StampDraft {
        StampDraft(watermark: WatermarkSpec(text: text, pages: pages))
    }

    private func apply(_ draft: StampDraft, _ tab: DocumentTab, replace: Int? = nil) throws -> StampRun {
        try draft.apply(tab.document, fonts: FakeFonts(), codec: FakeCodec(), replace: replace)
    }

    func test_aWatermarkIsWrittenOnEveryPageAndUndoTakesItBack() throws {
        let tab = try open(3)

        let run = try apply(mark("DRAFT"), tab)
        XCTAssertTrue(try tab.commit("Add watermark"))

        XCTAssertEqual(run.pages, 3)
        XCTAssertEqual(stamps(tab).count, 1)
        let found = try XCTUnwrap(stamps(tab).first)
        XCTAssertEqual(found.kind, .watermark)
        XCTAssertEqual(found.label, "DRAFT")
        XCTAssertEqual(found.pages, [0, 1, 2])

        XCTAssertTrue(try tab.undo())
        XCTAssertTrue(stamps(tab).isEmpty)
    }

    func test_updatingKeepsTheRunsIdAndChangesWhatItDraws() throws {
        let tab = try open(3)
        let first = try apply(mark("DRAFT"), tab)
        try tab.commit("Add watermark")

        _ = try apply(mark("FINAL", pages: [0]), tab, replace: first.id)
        try tab.commit("Update stamp")

        XCTAssertEqual(stamps(tab).count, 1)
        let found = try XCTUnwrap(stamps(tab).first)
        XCTAssertEqual(found.id, first.id)
        XCTAssertEqual(found.label, "FINAL")
        XCTAssertEqual(found.pages, [0])
    }

    func test_removingARunLeavesTheOthers() throws {
        let tab = try open(2)
        let first = try apply(mark("ONE"), tab)
        _ = try apply(mark("TWO"), tab)
        try tab.commit("Add watermark")

        let pages = PdfStamper(tab.document).remove(first.id)
        try tab.commit("Remove stamp")

        XCTAssertEqual(pages, 2)
        XCTAssertEqual(stamps(tab).map(\.label), ["TWO"])
    }

    func test_batesNumbersContinueIntoTheNextDocument() throws {
        let tab = try open(3)
        let spec = HeaderFooterSpec(footer: HeaderFooterBand("", "", "{bates}"), fileName: "a.pdf",
                                    bates: BatesSpec(prefix: "ACME-", suffix: "", digits: 4, start: 10))

        let run = try apply(StampDraft(headerFooter: spec), tab)
        try tab.commit("Add Bates numbers")

        XCTAssertEqual(run.nextBates, 13)
        XCTAssertEqual(stamps(tab).map(\.kind), [.bates])
    }

    func test_headersGoOnTheOddPagesOnly() throws {
        let tab = try open(3)
        let (pages, error) = PageChoice.resolve(.odd, "", tab.pageCount)
        let spec = HeaderFooterSpec(header: HeaderFooterBand("", "{file}", ""), fileName: "a.pdf", pages: pages)

        _ = try apply(StampDraft(headerFooter: spec), tab)
        try tab.commit("Add header and footer")

        XCTAssertNil(error)
        XCTAssertEqual(stamps(tab).map(\.pages), [[0, 2]])
    }

    func test_aPictureWatermarkTakesTheFileThroughTheCodec() throws {
        let tab = try open(1)

        let run = try apply(StampDraft(watermark: WatermarkSpec(), picture: [1, 2, 3]), tab)
        try tab.commit("Add watermark")

        XCTAssertEqual(run.pages, 1)
        XCTAssertEqual(stamps(tab).map(\.label), ["image"])
    }

    func test_aPictureNoCodecCanReadIsRefusedAndNothingIsStamped() throws {
        let tab = try open(1)
        let draft = StampDraft(background: BackgroundSpec(), picture: [])

        XCTAssertThrowsError(try apply(draft, tab)) { XCTAssertTrue($0 is InvalidDataException) }

        XCTAssertTrue(stamps(tab).isEmpty)
    }

    func test_textNoFontCanDrawLeavesTheDocumentAlone() throws {
        let tab = try open(1)

        XCTAssertThrowsError(try apply(mark("ğş"), tab)) { error in
            XCTAssertEqual((error as? InvalidOperationException)?.message, StampsText.noFont)
        }

        XCTAssertFalse(try tab.commit("Add watermark"))
    }

    func test_aDraftWithNothingToDrawSaysSo() {
        XCTAssertEqual(mark("  ").problem, StampsText.needsContent)
        XCTAssertEqual(StampDraft(background: BackgroundSpec()).problem, StampsText.needsContent)
        XCTAssertNotNil(StampDraft(headerFooter: HeaderFooterSpec()).problem)
        XCTAssertNil(StampDraft(headerFooter: HeaderFooterSpec(bates: BatesSpec())).problem)
        XCTAssertNil(StampDraft(background: BackgroundSpec(color: .gray(0.9))).problem)
        XCTAssertNil(StampDraft(watermark: WatermarkSpec(), picture: [1]).problem)
    }
}
