import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/compare/CompareSessionTests.cs and CompareRowTests.cs: the comparison behind the
// panel, Core's differences as rows, the filters, the pixel mode and the report.

@MainActor
final class CompareSessionTests: XCTestCase {
    private func pages(_ count: Int) -> [UInt8] {
        Pdfs.text(count, "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda.")
    }

    private func pixelSession(_ before: [UInt8], _ after: [UInt8], _ renderers: @escaping () -> DocumentRenderer) async throws -> CompareSession {
        let session = try CompareSession(CompareSide(bytes: before, name: "old.pdf", password: nil),
                                         CompareSide(bytes: after, name: "new.pdf", password: nil), renderers)
        try await session.compare(CompareOptions(), byPixels: true)
        return session
    }

    func test_everyKindOfDifferenceBecomesARow() async throws {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }

        let rows = session.rows(.all)

        XCTAssertEqual(rows.count, session.result!.changes.count)
        XCTAssertTrue(rows.contains { $0.title == "other" && $0.kind == .added })
        XCTAssertTrue(rows.contains { $0.title.contains("name") })
        XCTAssertTrue(rows.allSatisfy { !$0.spoken.isEmpty })
    }

    func test_aTextRowKnowsItsPageAndWhereOnThePageItIs() async throws {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }

        let row = try XCTUnwrap(session.rows(.text).first { $0.title == "other" })

        XCTAssertEqual(row.newPage, 0)
        XCTAssertEqual(row.subtitle, "Added · Page 1")
        let area = try XCTUnwrap(row.newArea)
        let page = PageGeometry(session.new.document.pages[0])
        XCTAssertTrue((0...page.width).contains(area.x))
        XCTAssertTrue((0...page.height).contains(area.y))
        XCTAssertGreaterThan(area.height, 0)
    }

    func test_theFiltersKeepOnlyWhatIsSwitchedOn() async throws {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }

        XCTAssertTrue(session.rows(.forms).allSatisfy { $0.title.contains("name") })
        XCTAssertEqual(session.rows(.forms).count, 1)
        XCTAssertTrue(session.rows(.details).contains { $0.title.contains("Title") })
        XCTAssertTrue(session.rows([.pictures, .annotations]).isEmpty)
        XCTAssertEqual(session.rows(.all).count, session.rows(.text).count + session.rows(.forms).count + session.rows(.details).count)
    }

    func test_theSameFileTwiceHasNothingToShow() async throws {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.before())
        defer { session.dispose() }

        XCTAssertTrue(session.result!.isIdentical)
        XCTAssertTrue(session.rows(.all).isEmpty)
        XCTAssertEqual(CompareFlow.headline(session, 0), "No differences found.")
    }

    func test_thePanelHeadlineCountsWhatIsShown() async throws {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }

        XCTAssertEqual(CompareFlow.headline(session, session.rows(.all).count), "\(session.rows(.all).count) differences")
        XCTAssertEqual(CompareFlow.headline(session, 0), "Nothing to show with these filters.")
        XCTAssertTrue(CompareFlow.note(session)?.hasPrefix("Words: ") == true)
    }

    func test_pixelModeFindsTheBlockOnEachPage() async throws {
        let session = try await pixelSession(CompareKit.before(), CompareKit.before(), CompareKit.painted())
        defer { session.dispose() }

        let rows = session.rows(.text)

        XCTAssertTrue(session.byPixels)
        XCTAssertEqual(Set(rows.map(\.newPage)), [0, 1])
        XCTAssertTrue(rows.allSatisfy { $0.kind == nil })
        let area = try XCTUnwrap(rows[0].newArea)
        // 96 dpi pixels are 0.75 pt: the region covers the block.
        XCTAssertTrue(area.contains(ViewPoint(67.5, 90)))
        XCTAssertEqual(CompareFlow.headline(session, 2), "2 areas differ")
    }

    func test_thePictureOfAPageShowsWhereItChanged() async throws {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.before(), CompareKit.painted())
        defer { session.dispose() }

        let drawn = await session.overlay(0)
        let overlay = try XCTUnwrap(drawn)

        XCTAssertEqual(overlay.width, 200)
        XCTAssertEqual(overlay.height, 300)
        let at = (120 * 200 + 90) * 4
        XCTAssertGreaterThan(overlay.rgba[at + 1], overlay.rgba[at], "ink only the new page has is green")
        let missing = await session.overlay(5)
        XCTAssertNil(missing)
    }

    func test_thePictureOfAnAddedPageIsNotMade() async throws {
        let session = try await CompareKit.session(pages(1), pages(2))
        defer { session.dispose() }

        let added = try XCTUnwrap(session.result!.pages.first { $0.isAdded }).newIndex

        let picture = await session.overlay(added)
        XCTAssertNil(picture)
    }

    func test_theReportIsAFileThatOpensAgainWithTheSummaryInFront() async throws {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }

        let report = try session.reportWork(.all, FakeFonts())()

        let again = try PdfDocument.open(report)
        XCTAssertGreaterThan(again.pages.count, session.new.pageCount)
        let text = ComparisonReport.toText(session.result!, "old.pdf", "new.pdf")
        XCTAssertTrue(text.contains("other"))
    }

    func test_aReportOfOneKindLeavesTheOthersOut() async throws {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }

        let only = ChangeParts.only(session.result!, .forms)

        XCTAssertEqual(only.changes.count, 1)
        XCTAssertEqual(only.summary.total, 1)
        XCTAssertEqual(only.summary.document, 1)
        XCTAssertEqual(only.summary.text, 0)
        XCTAssertEqual(ChangeParts.only(session.result!, .all).changes.count, session.result!.changes.count)
    }

    func test_aPixelComparisonListsAddedAndRemovedPages() async throws {
        let session = try await pixelSession(pages(3), pages(2), CompareKit.painted())
        defer { session.dispose() }

        let rows = session.rows(.all)

        XCTAssertTrue(rows.contains { $0.kind == .removed && $0.newPage < 0 })
        XCTAssertEqual(rows.first { $0.kind == .removed }?.title, "Page removed")
        XCTAssertNotEqual(CompareFlow.headline(session, rows.count), "No differences found.")
    }

    func test_pagesThatCannotBeDrawnAreNotCalledTheSame() async throws {
        let session = try await pixelSession(CompareKit.before(), CompareKit.before(), CompareKit.undrawn())
        defer { session.dispose() }

        XCTAssertTrue(session.rows(.all).isEmpty)
        XCTAssertEqual(CompareFlow.headline(session, 0), "Pages could not be drawn.")
        XCTAssertEqual(CompareFlow.note(session), "2 pages could not be drawn.")
    }

    func test_aNoisyPageDoesNotUseUpTheList() async throws {
        let session = try await pixelSession(CompareKit.before(), CompareKit.before(), CompareKit.speckled())
        defer { session.dispose() }

        let rows = session.rows(.all)

        XCTAssertEqual(Set(rows.map(\.newPage)), [0, 1])
        XCTAssertEqual(rows.filter { $0.newPage == 0 }.count, 50)
        XCTAssertNil(CompareFlow.note(session))
    }

    // CompareRowTests

    private func page(_ width: Double, _ height: Double) -> PageGeometry {
        PageGeometry(PdfRect(0, 0, width, height), 0)
    }

    func test_aBiggerOldPageScalesTheBox() async {
        let box = ChangeRow.oldBox(ViewRect(10, 20, 30, 40), PixelAlignment(0, 0, 0), 96, page(200, 300), page(100, 150))

        XCTAssertEqual(box, ViewRect(20, 40, 60, 80))
    }

    func test_aShiftedRescanMovesTheBoxBack() async {
        let box = ChangeRow.oldBox(ViewRect(10, 20, 30, 40), PixelAlignment(8, -16, 0), 96, page(100, 150), page(100, 150))

        XCTAssertEqual(box, ViewRect(4, 32, 30, 40))
    }

    func test_aTurnedPageKeepsTheCentreWhereItIs() async {
        let box = ChangeRow.oldBox(ViewRect(45, 45, 10, 10), PixelAlignment(0, 0, 90), 96, page(100, 100), page(100, 100))

        XCTAssertEqual(box.x + box.width / 2, 50, accuracy: 1e-6)
        XCTAssertEqual(box.y + box.height / 2, 50, accuracy: 1e-6)
    }

    func test_aFormValueShowsInTheRow() async throws {
        let session = try await CompareKit.session(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }

        let rows = session.rows(.forms)

        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].oldPage < 0 && rows[0].newPage < 0)
        XCTAssertTrue(rows[0].subtitle.contains("Ann"))
    }
}

@MainActor
final class ViewSyncPartnerTests: XCTestCase {
    // Old pages 0 1 2 3 against new pages 0 1 2 3 4: old 1 is gone, new 2 was added.
    private let pairs = [
        PagePair(0, 0, 1, false),
        PagePair(1, -1, 0, false),
        PagePair(2, 1, 0.9, false),
        PagePair(-1, 2, 0, false),
        PagePair(3, 3, 1, false),
        PagePair(-1, 4, 0, false),
    ]

    func test_aPairedPageGoesToItsPartner() async {
        for (old, partner) in [(0, 0), (2, 1), (3, 3)] {
            XCTAssertEqual(ViewSync.partner(pairs, old, fromOld: true), partner)
        }
    }

    func test_aRemovedPageGoesToTheNextPageThatSurvived() async {
        XCTAssertEqual(ViewSync.partner(pairs, 1, fromOld: true), 1)
    }

    func test_anAddedPageGoesToTheNextPageOfTheOldFile() async {
        XCTAssertEqual(ViewSync.partner(pairs, 2, fromOld: false), 3)
    }

    func test_anAddedPageAtTheEndFallsBackToThePageBefore() async {
        XCTAssertEqual(ViewSync.partner(pairs, 4, fromOld: false), 3)
    }

    func test_aPageNoPairNamesHasNoPartner() async {
        XCTAssertEqual(ViewSync.partner(pairs, 9, fromOld: true), -1)
    }
}
