#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Smoke tests of AppWindow drawn at the size of a Mac window and of an iPhone: each state of the window is set on the view
// model, drawn, and the picture checked for being more than a blank sheet. What the buttons do is the view model's, and
// is tested in LazyPDFAppTests.

@MainActor
final class AppWindowTests: XCTestCase {
    private let sizes: [(name: String, width: CGFloat, height: CGFloat)] = [("Mac", 1200, 800), ("iPhone", 390, 844)]

    private func drawn(_ f: ShellFixture, file: StaticString = #filePath, line: UInt = #line) {
        for size in sizes {
            guard let image = picture(f.window(), size.width, size.height) else {
                XCTFail("The window did not draw at \(size.name) size.", file: file, line: line)
                continue
            }
            XCTAssertEqual(image.width, Int(size.width), size.name, file: file, line: line)
            XCTAssertEqual(image.height, Int(size.height), size.name, file: file, line: line)
            XCTAssertGreaterThan(variety(image), 8, size.name, file: file, line: line)
        }
    }

    func test_homeDraws() {
        let f = ShellFixture(self)

        XCTAssertTrue(f.vm.isHome)
        drawn(f)
    }

    func test_homeDrawsWithRecentFiles() async {
        let f = ShellFixture(self)
        await f.openDocuments(2)
        f.vm.select(HomeTab.shared)

        XCTAssertFalse(f.vm.recent.isEmpty)
        drawn(f)
    }

    func test_twoDocumentsDraw() async {
        let f = ShellFixture(self)

        await f.openDocuments(2)

        XCTAssertEqual(f.vm.strip.count, 3)
        XCTAssertNotNil(f.vm.activeDocument)
        drawn(f)
    }

    func test_anOpenToolAndAPanelDraw() async {
        let f = ShellFixture(self)
        await f.openDocuments(1)

        f.vm.setSidePanel("search")
        f.vm.selectTool("stamps")

        XCTAssertEqual(f.vm.activeTool?.id, "stamps")
        drawn(f)
    }

    func test_theInfoBarDraws() async {
        let f = ShellFixture(self)
        await f.openDocuments(1)

        f.vm.showProblem(Problem("Not saved", "Check the disk."))
        XCTAssertEqual(f.vm.message?.isError, true)
        drawn(f)

        f.vm.showNotice("File changed", "By another program.", NoticeAction("Open that version") {})
        XCTAssertEqual(f.vm.message?.action?.text, "Open that version")
        drawn(f)
    }

    func test_theBusyBarDrawsWhileAJobRuns() async {
        let f = ShellFixture(self)
        await f.openDocuments(1)
        let started = Gate()
        let finish = Gate()
        let vm = f.vm
        let job = Task {
            try await vm.runBusy("Reading page 2 of 9") { _ in
                started.release()
                await finish.wait()
            }
        }
        await started.wait()

        XCTAssertTrue(f.vm.isBusy)
        XCTAssertEqual(f.vm.busyText, "Reading page 2 of 9")
        drawn(f)

        finish.release()
        try? await job.value
        XCTAssertFalse(f.vm.isBusy)
    }

    func test_theStatusLineDraws() async {
        let f = ShellFixture(self)
        await f.openDocuments(1)

        f.vm.setStatus("Saved report.pdf. The old version is in the file's history.")

        drawn(f)
    }

    func test_aLockedFileAsksForItsPassword() async {
        let f = ShellFixture(self)

        await f.vm.open(f.file("locked.pdf", StandInPdfs.fixture("locked.pdf")))

        let request = f.vm.passwordRequest
        XCTAssertEqual(request?.name, "locked.pdf")
        XCTAssertEqual(request?.needsCertificate, false)
        drawn(f)
        if let request {
            XCTAssertNotNil(picture(PasswordSheet(vm: f.vm, request: request), 420, 260))
        }
    }

    func test_aFileForRecipientsAsksForACertificate() async throws {
        let f = ShellFixture(self)

        await f.vm.open(f.file("recipients.pdf", StandInPdfs.forRecipients()))

        let request = try XCTUnwrap(f.vm.passwordRequest)
        XCTAssertTrue(request.needsCertificate)
        XCTAssertEqual(request.certificates.map(\.name), ["Alice"])
        let image = try XCTUnwrap(picture(PasswordSheet(vm: f.vm, request: request, importCertificate: { nil }), 420, 400))
        XCTAssertGreaterThan(variety(image), 8)
    }

    func test_theCloseQuestionDraws() async {
        let f = ShellFixture(self)
        await f.openDocuments(1)
        let tab = f.vm.activeDocument!
        tab.pendingMarks = 2

        XCTAssertFalse(f.vm.requestClose(tab))

        XCTAssertTrue(f.vm.closeQuestion === tab)
        drawn(f)
    }

    func test_theCloseCardsDraw() async throws {
        let f = ShellFixture(self)
        await f.openDocuments(1)
        let tab = f.vm.activeDocument!
        tab.pendingMarks = 1
        let marksOnly = try XCTUnwrap(picture(CloseCard(tab: tab, save: {}, discard: {}, cancel: {}), 480, 300))
        XCTAssertGreaterThan(variety(marksOnly), 8)

        var metadata = DocumentMetadata.read(tab.document)
        metadata.title = "x"
        try metadata.write(tab.document)
        try tab.commit("x")
        XCTAssertTrue(tab.isDirty)
        let unsaved = try XCTUnwrap(picture(CloseCard(tab: tab, save: {}, discard: {}, cancel: {}), 480, 300))
        XCTAssertGreaterThan(variety(unsaved), 8)
    }

    func test_theRecoveryCardDraws() throws {
        let card = RecoveryCard(titles: ["a.pdf", "b.pdf"], restore: {}, discard: {})

        let image = try XCTUnwrap(picture(card, 520, 340))

        XCTAssertGreaterThan(variety(image), 8)
    }

    func test_settingsAndAboutDraw() throws {
        let f = ShellFixture(self)

        let settings = try XCTUnwrap(picture(SettingsView(vm: f.vm, about: {}, done: {}), 480, 300))
        let about = try XCTUnwrap(picture(AboutView(done: {}), 560, 520))

        XCTAssertGreaterThan(variety(settings), 8)
        XCTAssertGreaterThan(variety(about), 8)
    }

    func test_theAppearanceFollowsThePreference() {
        let f = ShellFixture(self)

        f.vm.setAppearance(.dark)
        drawn(f)
        f.vm.setAppearance(.light)
        drawn(f)

        XCTAssertEqual(f.vm.appearance, .light)
    }

    func test_theDocumentSummaryListsTheFactsOfTheFile() async throws {
        let f = ShellFixture(self)
        await f.openDocuments(1)
        let tab = try XCTUnwrap(f.vm.activeDocument)

        let facts = DocumentSummary.facts(tab)

        XCTAssertEqual(facts.map(\.label), ["File", "Folder", "Pages", "PDF version", "Size", "Protection"])
        XCTAssertEqual(facts.first?.value, "doc1.pdf")
        XCTAssertEqual(facts.first { $0.label == "Pages" }?.value, "1")
        XCTAssertEqual(facts.first { $0.label == "Protection" }?.value, "Not protected")
    }

    func test_sizesAreWrittenInTheUnitThatFits() {
        XCTAssertEqual(DocumentSummary.size(512), "512 bytes")
        XCTAssertEqual(DocumentSummary.size(1536), "1.5 KB")
        XCTAssertEqual(DocumentSummary.size(3 * 1_048_576), "3 MB")
    }

    func test_everySymbolOfTheCatalogExists() {
        var names = ToolCatalog.tools.map(\.symbol) + ToolCatalog.sidePanels.map(\.symbol)
        names += ToolGroup.allCases.map(ToolCatalog.groupSymbol)
        names += ["house", "doc", "sidebar.left", "wrench.and.screwdriver", "doc.richtext", "arrow.down.doc", "chevron.down"]
        for name in names {
            #if canImport(AppKit)
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
            #elseif canImport(UIKit)
            XCTAssertNotNil(UIImage(systemName: name), name)
            #endif
        }
    }
}
#endif
