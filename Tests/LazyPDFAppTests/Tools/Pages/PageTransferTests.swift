import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Follows windows/LazyPDF.App.Tests/Tools/pages/PageTransferTests.cs: pages copied from the tab in view into another one, or into a
// tab of their own. The window is the source's, so its notices are the ones the person sees.

private final class LoadingRenderer: DocumentRenderer {
    var loadsInBackground: Bool { true }
    func load(_ session: PdfEditSession, _ password: String?) -> Bool { true }
    func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) { (200, 300) }
    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? { nil }
    func close() {}

    @MainActor
    func loadAsync(_ session: PdfEditSession, _ password: String?) async -> Bool {
        await withCheckedContinuation { (_: CheckedContinuation<Bool, Never>) in }
    }
}

private struct Refused: Error {}

@MainActor
final class PageTransferTests: XCTestCase {
    private func pair(from: [UInt8] = Pdfs.text(6, "From"), to: [UInt8] = Pdfs.text(6, "To")) throws -> (a: PagesRig, b: PagesRig) {
        let a = try PagesRig(from, title: "a.pdf")
        let b = try PagesRig(to, title: "b.pdf")
        a.host.openDocuments = [a.tab, b.tab]
        return (a, b)
    }

    private func payload(_ rig: PagesRig, _ pages: [Int]) -> PageDragPayload {
        PageDragPayload(tab: rig.tab, grid: nil, pages: pages)
    }

    func test_pagesGoToTheEndOfTheOtherTabAsOneStepThere() async throws {
        let (a, b) = try pair()
        let fromOrder = a.tab.order, toOrder = b.tab.order

        await PageTransfer.copy(payload(a, [1, 2]), to: b.tab, host: a.host)

        XCTAssertEqual(b.tab.order, toOrder + [fromOrder[1], fromOrder[2]])
        XCTAssertEqual(a.tab.order, fromOrder)
        XCTAssertFalse(a.tab.session.canUndo)
        XCTAssertEqual(a.host.statuses.last, "Copied 2 pages to b.pdf. Undo it in b.pdf.")
        XCTAssertTrue(a.host.problems.isEmpty)
        try b.tab.undo()
        XCTAssertEqual(b.tab.order, toOrder)
        XCTAssertFalse(b.tab.session.canUndo)
    }

    func test_aOnePageTabTakesThem() async throws {
        let (a, b) = try pair(to: Pdfs.text(1, "To"))

        await PageTransfer.copy(payload(a, [0, 5]), to: b.tab, host: a.host)

        XCTAssertEqual(b.tab.pageCount, 3)
    }

    func test_aRotatedPageKeepsItsSizeInTheOtherFile() async throws {
        let (a, b) = try pair(to: Pdfs.text(1, "To"))
        PageOperations.rotate(a.tab.document, [1], 90)
        try a.tab.commit("Rotate")
        let shown = PageGeometry(a.tab.document.pages[1])

        await PageTransfer.copy(payload(a, [1]), to: b.tab, host: a.host)

        let copied = PageGeometry(b.tab.document.pages[1])
        XCTAssertEqual(copied.width, shown.width, accuracy: 0.01)
        XCTAssertEqual(copied.height, shown.height, accuracy: 0.01)
    }

    func test_pagesThatAreGoneFromTheSourceAreRefused() async throws {
        let (a, b) = try pair()
        let drag = payload(a, [4, 5])
        try PageOperations.delete(a.tab.document, [3, 4, 5])
        try a.tab.commit("Delete")

        await PageTransfer.copy(drag, to: b.tab, host: a.host)

        XCTAssertEqual(b.tab.pageCount, 6)
        XCTAssertEqual(a.host.problems.map(\.title), ["Pages not copied"])
        XCTAssertEqual(a.host.problems.first?.text, "The pages changed since they were picked. Pick them again.")
    }

    func test_anEditOfTheSourceAfterThePickRefusesTheCopy() async throws {
        let (a, b) = try pair()
        let drag = payload(a, [0])
        PageOperations.rotate(a.tab.document, [3], 90)
        try a.tab.commit("Rotate")

        await PageTransfer.copy(drag, to: b.tab, host: a.host)

        XCTAssertEqual(b.tab.pageCount, 6)
        XCTAssertEqual(a.host.problems.map(\.title), ["Pages not copied"])
    }

    func test_aTabThatIsNotOpenAnyMoreIsRefused() async throws {
        let (a, b) = try pair()
        a.host.openDocuments = [a.tab]

        await PageTransfer.copy(payload(a, [0]), to: b.tab, host: a.host)

        XCTAssertEqual(b.tab.pageCount, 6)
        XCTAssertEqual(a.host.problems.first?.text, "One of the two files is not open any more.")

        a.host.problems = []
        a.host.openDocuments = [a.tab, b.tab]
        let gone = payload(a, [0])
        a.tab.dispose()
        await PageTransfer.copy(gone, to: b.tab, host: a.host)
        XCTAssertEqual(a.host.problems.first?.text, "One of the two files is not open any more.")
    }

    func test_theSameTabIsLeftAlone() async throws {
        let (a, _) = try pair()

        await PageTransfer.copy(payload(a, [0]), to: a.tab, host: a.host)

        XCTAssertEqual(a.tab.pageCount, 6)
        XCTAssertTrue(a.host.problems.isEmpty)
        XCTAssertTrue(a.host.notices.isEmpty)
    }

    func test_aRunningJobAndATargetThatIsStillLoadingAreRefusedWithAWord() async throws {
        let (a, b) = try pair()
        MarkWork.shared.running = true
        await PageTransfer.copy(payload(a, [0]), to: b.tab, host: a.host)
        MarkWork.shared.running = false
        XCTAssertEqual(a.host.problems.last?.text, "Wait for the running job to finish, then try again.")

        let slow = DocumentTab(session: try PdfEditSession.open(Pdfs.text(2)), renderer: LoadingRenderer(), url: nil, title: "c.pdf")
        try Pdfs.retitle(slow.session, "One")
        try slow.commit("Properties")
        a.host.openDocuments.append(slow)
        await PageTransfer.copy(payload(a, [0]), to: slow, host: a.host)

        XCTAssertEqual(a.host.problems.last?.text, "c.pdf is still loading. Try again in a moment.")
        XCTAssertEqual(slow.pageCount, 2)
    }

    func test_aSourceThatLimitsCopyingCannotBeCopiedFrom() async throws {
        let (a, b) = try pair(from: Pdfs.restricted(.print, pages: 3))

        await PageTransfer.copy(payload(a, [0]), to: b.tab, host: a.host)

        XCTAssertEqual(a.host.problems.map(\.title), ["File is protected"])
        XCTAssertEqual(b.tab.pageCount, 6)
    }

    func test_aProtectedSourceThatMayBeCopiedSaysTheCopyIsNot() async throws {
        let (a, b) = try pair(from: Pdfs.restricted(.all, pages: 3))

        await PageTransfer.copy(payload(a, [0]), to: b.tab, host: a.host)

        XCTAssertEqual(b.tab.pageCount, 7)
        XCTAssertEqual(a.host.notices.map(\.title), ["Copy is not protected"])
    }

    func test_aTargetThatForbidsChangesIsNamedInTheRefusal() async throws {
        let (a, b) = try pair(to: Pdfs.restricted(.print, pages: 3))
        let revision = b.tab.revision

        await PageTransfer.copy(payload(a, [0]), to: b.tab, host: a.host)

        XCTAssertEqual(a.host.problems.map(\.title), ["b.pdf cannot be changed"])
        XCTAssertEqual(b.tab.revision, revision)
    }

    func test_aSignedTargetIsNamedAndTheCopyWaitsForGoOnAnyway() async throws {
        let (a, b) = try pair(to: Pdfs.signed(certified: false, pages: 3))
        let revision = b.tab.revision

        await PageTransfer.copy(payload(a, [0]), to: b.tab, host: a.host)

        XCTAssertEqual(a.host.notices.map(\.text), ["b.pdf is signed, so changing it breaks the signatures."])
        XCTAssertEqual(b.tab.revision, revision)

        a.host.notices[0].action?.run()
        await waitUntil { b.tab.revision != revision }

        XCTAssertEqual(b.tab.pageCount, 4)
        XCTAssertEqual(a.host.notices.count, 1)
        XCTAssertTrue(a.host.problems.isEmpty)
    }

    func test_aChangeThatTheFileDoesNotTakeEndsAsPagesNotChanged() async throws {
        let (a, b) = try pair()
        let before = b.tab.session.current

        let done = await PageJobs.applyAsync(b.tab, a.host, busy: "Adding", label: "Paste", { _ in throw Refused() }, status: "Done")

        XCTAssertFalse(done)
        XCTAssertEqual(b.tab.session.current, before)
        XCTAssertEqual(a.host.problems.map(\.title), ["Pages not changed"])
    }

    func test_aTargetThatGotShorterTakesThePagesAtItsActualEnd() async throws {
        let (_, b) = try pair(to: Pdfs.text(2, "To"))
        let pdf = Pdfs.text(2, "Pasted")

        try PageTransfer.importer(pdf, at: 9)(b.tab.document)
        XCTAssertEqual(b.tab.pageCount, 4)
        try b.tab.commit("Paste")
        await PageTransfer.paste(b.tab, b.host, pdf, count: 2, at: 40)

        XCTAssertEqual(b.tab.pageCount, 6)
        XCTAssertTrue(b.host.problems.isEmpty)
    }

    func test_aCancelledCopyChangesNeitherTab() async throws {
        let (a, b) = try pair()
        a.host.cancelsBusy = true
        let before = b.tab.session.current

        let done = await PageJobs.applyAsync(b.tab, a.host, busy: "Adding", label: "Paste", { document in
            try PageOperations.duplicate(document, [0])
            Thread.sleep(forTimeInterval: 0.3)
        }, status: "Done")

        XCTAssertFalse(done)
        XCTAssertEqual(b.tab.session.current, before)
        XCTAssertEqual(a.host.statuses.last, "Canceled.")
    }

    func test_aNewTabGetsThePagesWithoutAttachments() async throws {
        let (a, _) = try pair()
        let fromOrder = a.tab.order

        await PageTransfer.toNewTab(payload(a, [2, 3]), a.host, files: false)

        let opened = try XCTUnwrap(a.host.openedNew.first)
        XCTAssertEqual(opened.title, "a extract.pdf")
        XCTAssertEqual(try PdfDocument.open(opened.pdf).pages.count, 2)
        XCTAssertEqual(a.host.statuses.last, "2 pages extracted")
        XCTAssertEqual(a.tab.order, fromOrder)
        XCTAssertFalse(a.tab.session.canUndo)
    }

    func test_aNewTabFromPagesThatChangedIsRefused() async throws {
        let (a, _) = try pair()
        let drag = payload(a, [2])
        PageOperations.rotate(a.tab.document, [3], 90)
        try a.tab.commit("Rotate")

        await PageTransfer.toNewTab(drag, a.host, files: false)

        XCTAssertTrue(a.host.openedNew.isEmpty)
        XCTAssertEqual(a.host.problems.map(\.title), ["Pages not copied"])
    }
}
