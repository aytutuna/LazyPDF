import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/compare/CompareFlowTests.cs and CompareReportTests.cs: running the tool as the shell
// does, the busy bar, the problem for a file that cannot be read, the report as a new tab, what the report says about the
// filters, what it keeps of the new file's protection, and when it is refused or dropped.

@MainActor
final class CompareFlowTests: XCTestCase {
    private func makeFlow(_ f: ViewModelFixture) -> CompareFlow {
        CompareFlow(f.vm, { FakeRenderer() }, FakeFonts())
    }

    private func request(_ url: URL?, version: PdfVersion? = nil, fileIsOlder: Bool = false, pixels: Bool = false) -> CompareRequest {
        CompareRequest(url: url, version: version, fileIsOlder: fileIsOlder, byPixels: pixels)
    }

    private func open(_ f: ViewModelFixture, _ bytes: [UInt8] = CompareKit.before()) async -> DocumentTab {
        await f.vm.open(f.dir.file("open.pdf", bytes))
        return f.vm.activeDocument!
    }

    private func twoRevisions() throws -> [UInt8] {
        let session = try PdfEditSession.open(Pdfs.text(2))
        try Pdfs.retitle(session, "Changed title")
        try session.commit("Properties")
        return session.current
    }

    func test_anotherFileIsTheOldSideUnlessTheOpenFileIsOlder() async throws {
        let f = ViewModelFixture(self)
        let other = f.dir.file("other.pdf", try CompareKit.after())
        let tab = await open(f)

        let olderFound = try await makeFlow(f).run(tab, request(other))
        let older = try XCTUnwrap(olderFound)
        let newerFound = try await makeFlow(f).run(tab, request(other, fileIsOlder: true))
        let newer = try XCTUnwrap(newerFound)
        defer {
            older.dispose()
            newer.dispose()
        }

        XCTAssertEqual([older.old.title, older.new.title], ["other.pdf", "open.pdf"])
        XCTAssertEqual([newer.old.title, newer.new.title], ["open.pdf", "other.pdf"])
        XCTAssertTrue(older.result!.changes.contains { $0.kind == .removed && $0.area == .document })
        XCTAssertTrue(newer.result!.changes.contains { $0.kind == .added && $0.area == .document })
        XCTAssertEqual(f.vm.statusFull, "\(newer.rows(.all).count) differences")
        XCTAssertFalse(f.vm.isBusy)
    }

    func test_anEarlierVersionIsComparedWithTheOpenFile() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, try twoRevisions())
        let earlier = try XCTUnwrap(CompareFlow.earlier(tab.session).first)
        XCTAssertEqual(CompareFlow.earlier(tab.session).count, 1)

        let madeFound = try await makeFlow(f).run(tab, request(nil, version: earlier))
        let made = try XCTUnwrap(madeFound)
        defer { made.dispose() }

        XCTAssertEqual(made.old.title, "open.pdf, version 1")
        XCTAssertEqual(made.result!.changes.count, 1)
        XCTAssertEqual(made.result!.changes[0].oldText, "")
        XCTAssertEqual(made.result!.changes[0].newText, "Changed title")
    }

    func test_aFileWithNoHistoryHasNoEarlierVersion() async {
        let f = ViewModelFixture(self)
        let tab = await open(f)

        XCTAssertTrue(CompareFlow.earlier(tab.session).isEmpty)
    }

    func test_editsNotYetSavedMakeTheOpenedStateAnEarlierVersion() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        try Pdfs.retitle(tab.session, "Edited")
        try tab.commit("Properties")

        XCTAssertEqual(CompareFlow.earlier(tab.session).count, 1)
    }

    func test_theOpenFileIsReadAsItWasWhenTheToolRan() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, Pdfs.text(2))
        let other = f.dir.file("other.pdf", try CompareKit.after())

        let madeFound = try await makeFlow(f).run(tab, request(other, fileIsOlder: true))
        let made = try XCTUnwrap(madeFound)
        defer { made.dispose() }
        try Pdfs.retitle(tab.session, "Later")
        try tab.commit("Properties")

        XCTAssertFalse(made.result!.changes.contains { $0.newText == "Later" || $0.oldText == "Later" })
        XCTAssertNotEqual(DocumentMetadata.read(made.old.document).title, "Later")
    }

    func test_aFileThatIsGoneIsAProblemNotACrash() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)

        let made = try await makeFlow(f).run(tab, request(f.dir.sub("gone.pdf")))

        XCTAssertNil(made)
        XCTAssertEqual(f.vm.message?.title, "File not found")
        XCTAssertFalse(f.vm.isBusy)
    }

    func test_aFileThatIsNotAPdfIsAProblem() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let junk = f.dir.file("junk.pdf", Array("not a pdf at all".utf8))

        let made = try await makeFlow(f).run(tab, request(junk))

        XCTAssertNil(made)
        XCTAssertEqual(f.vm.message?.title, "Not a PDF")
    }

    func test_cancellingGivesNothingBack() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let other = f.dir.file("other.pdf", try CompareKit.after())

        let made = try await CompareFlow(CancellingHost(), { FakeRenderer() }, FakeFonts()).run(tab, request(other))

        XCTAssertNil(made)
    }

    func test_theReportOpensAsANewDocumentThatNeedsAName() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let other = f.dir.file("other.pdf", try CompareKit.after())
        let madeFound = try await makeFlow(f).run(tab, request(other, fileIsOlder: true))
        let made = try XCTUnwrap(madeFound)
        defer { made.dispose() }

        await makeFlow(f).writeReport(made, .all)

        let report = f.vm.activeDocument!
        XCTAssertEqual(report.title, "Comparison - other.pdf")
        XCTAssertGreaterThan(report.pageCount, made.new.pageCount)
        XCTAssertTrue(AppViewModel.needsName(report))
    }

    func test_aLockedOtherFileAsksForItsPasswordInsteadOfFailing() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let locked = f.dir.file("locked.pdf", try CompareKit.locked("pw"))
        let flow = makeFlow(f)

        let first = try await flow.run(tab, request(locked))
        XCTAssertNil(first)
        XCTAssertEqual(flow.locked, .passwordRequired)
        XCTAssertNil(f.vm.message)

        var again = request(locked)
        again.password = "pw"
        let madeFound = try await flow.run(tab, again)
        let made = try XCTUnwrap(madeFound)
        defer { made.dispose() }
        XCTAssertNil(flow.locked)
        XCTAssertEqual(made.old.title, "locked.pdf")
    }

    func test_aWrongPasswordIsAskedAgain() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let flow = makeFlow(f)
        var wrong = request(f.dir.file("locked.pdf", try CompareKit.locked("pw")))
        wrong.password = "nope"

        let made = try await flow.run(tab, wrong)

        XCTAssertNil(made)
        XCTAssertEqual(flow.locked, .passwordRequired)
    }

    // CompareReportTests

    private func compared(_ before: [UInt8], _ after: [UInt8], password: String? = nil) async throws -> CompareSession {
        let session = try CompareSession(CompareSide(bytes: before, name: "old.pdf", password: nil),
                                         CompareSide(bytes: after, name: "new.pdf", password: password), { FakeRenderer() })
        try await session.compare(CompareOptions(), byPixels: false)
        return session
    }

    func test_aProtectedFileStaysProtectedInTheReport() async throws {
        let session = try await compared(CompareKit.before(), CompareKit.locked("pw"), password: "pw")
        defer { session.dispose() }

        let report = try session.reportWork(.all, FakeFonts())()

        XCTAssertThrowsError(try PdfDocument.open(report))
        let opened = try PdfDocument.open(report, password: "pw")
        XCTAssertGreaterThan(opened.pages.count, session.new.pageCount)
    }

    func test_theReportTabKeepsThePasswordSoNothingIsAskedAgain() async throws {
        let f = ViewModelFixture(self)
        _ = await open(f)
        let session = try await compared(CompareKit.before(), CompareKit.locked("pw"), password: "pw")
        defer { session.dispose() }

        await makeFlow(f).writeReport(session, .all)

        XCTAssertNil(f.vm.passwordRequest)
        XCTAssertEqual(f.vm.activeDocument?.password, "pw")
    }

    func test_aFileThatLimitsReadersCannotBeCopiedIntoAReport() async throws {
        let f = ViewModelFixture(self)
        _ = await open(f)
        let session = try await compared(CompareKit.before(), try Pdfs.restricted(.print))
        defer { session.dispose() }

        await makeFlow(f).writeReport(session, .all)

        XCTAssertFalse(session.canReport)
        XCTAssertEqual(f.vm.message?.title, "Report not allowed")
        XCTAssertEqual(f.vm.activeDocument?.title, "open.pdf")
    }

    func test_aFilteredReportSaysSoInItsNames() async throws {
        let f = ViewModelFixture(self)
        _ = await open(f)
        let session = try await compared(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }

        await makeFlow(f).writeReport(session, .forms)

        XCTAssertEqual(f.vm.activeDocument?.title, "Comparison, filtered - new.pdf")
    }

    func test_noReportIsWrittenWhenTheFiltersLeaveNothingOfRealDifferences() async throws {
        let f = ViewModelFixture(self)
        _ = await open(f)
        let session = try await compared(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }

        await makeFlow(f).writeReport(session, .pictures)

        XCTAssertEqual(f.vm.message?.title, "Nothing to report")
        XCTAssertEqual(f.vm.activeDocument?.title, "open.pdf")
    }

    func test_twoFilesThatAreTheSameStillGetAReport() async throws {
        let f = ViewModelFixture(self)
        _ = await open(f)
        let session = try await compared(CompareKit.before(), CompareKit.before())
        defer { session.dispose() }

        await makeFlow(f).writeReport(session, .pictures)

        XCTAssertNil(f.vm.message)
        XCTAssertEqual(f.vm.activeDocument?.title, "Comparison, filtered - new.pdf")
    }

    func test_leavingPagesOutLeavesRemovedPagesOutOfTheSummary() async throws {
        let line = "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda."
        let session = try await CompareKit.session(Pdfs.text(2, line), Pdfs.text(1, line))
        defer { session.dispose() }
        XCTAssertTrue(session.result!.pages.contains { $0.isRemoved })

        let kept = ChangeParts.only(session.result!, [.text, .details])

        XCTAssertTrue(kept.pages.contains { !$0.isRemoved })
        XCTAssertFalse(kept.pages.contains { $0.isRemoved })
        XCTAssertTrue(ChangeParts.only(session.result!, .all).pages.contains { $0.isRemoved })
    }

    func test_cancellingDropsTheReport() async throws {
        let session = try await compared(CompareKit.before(), CompareKit.after())
        defer { session.dispose() }
        let host = CancellingHost()

        await CompareFlow(host, { FakeRenderer() }, FakeFonts()).writeReport(session, .all)

        XCTAssertEqual(host.opened, 0)
    }

    func test_aPixelComparisonHasAReportToo() async throws {
        let f = ViewModelFixture(self)
        _ = await open(f)
        let session = try CompareSession(CompareSide(bytes: CompareKit.before(), name: "old.pdf", password: nil),
                                         CompareSide(bytes: CompareKit.before(), name: "new.pdf", password: nil), CompareKit.painted())
        defer { session.dispose() }
        try await session.compare(CompareOptions(), byPixels: true)

        await makeFlow(f).writeReport(session, .all)

        let report = f.vm.activeDocument!
        XCTAssertEqual(report.title, "Comparison - new.pdf")
        XCTAssertGreaterThan(report.pageCount, session.new.pageCount)
    }
}
