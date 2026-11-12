import Foundation
import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// What the model tests of the content group share: a window that records what it was told and can be made to cancel a job or to
// change the document before it starts, as windows/LazyPDF.App.Tests/Tools/stamps/PanelHarness.cs has it, and a tab with a
// viewer to attach a model to.

@MainActor
final class ContentHost: ToolHost {
    var problems: [Problem] = []
    var notices: [(title: String, text: String, action: NoticeAction?)] = []
    var statuses: [String] = []
    var fontSource: FontSource? = FakeFonts()
    var imageCodec: ImageCodec? = FakeCodec()

    /// Runs before the work starts, for a test that changes the document under it.
    var before: (() -> Void)?

    var cancelled = false
    var picked: [ToolFile] = []
    var exported: [URL] = []

    var status: String { statuses.last ?? "" }

    func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws {
        before?()
        let token = CancelToken()
        if cancelled { token.cancel() }
        do {
            try await work(token)
        } catch is CancellationError {
            statuses.append("Canceled.")
        }
    }

    func setBusyText(_ text: String) {}
    func showProblem(_ problem: Problem) { problems.append(problem) }
    func showNotice(_ title: String, _ text: String, _ action: NoticeAction?) { notices.append((title, text, action)) }
    func setStatus(_ sentence: String) { statuses.append(sentence) }
    func open(_ url: URL, access: FileAccess?) async {}
    func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async {}
    func tryReload(_ tab: DocumentTab) async -> Bool { true }

    var filePicker: ToolFilePicker { picker }
    var fileExporter: ToolFileExporter { picker }

    private lazy var picker = ContentPicker(self)
}

/// Hands over the files a test put in `picked` and keeps the copies it was asked to export.
@MainActor
final class ContentPicker: ToolFilePicker, ToolFileExporter {
    private unowned let host: ContentHost

    init(_ host: ContentHost) {
        self.host = host
    }

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] { host.picked }
    func pickFolder() async -> ToolFile? { nil }

    func export(_ files: [URL]) async -> ToolExport {
        host.exported = files.map { URL(fileURLWithPath: $0.lastPathComponent) }
        return ToolExport(saved: host.exported)
    }
}

@MainActor
struct ContentRig {
    let tab: DocumentTab
    let viewer: PanelViewer
    let host: ContentHost

    init(_ bytes: [UInt8]? = nil, password: String? = nil) throws {
        tab = DocumentTab(session: try PdfEditSession.open(bytes ?? Pdfs.text(2), password: password), renderer: FakeRenderer(), url: nil,
                          title: "a.pdf", password: password)
        viewer = PanelViewer(tab)
        host = ContentHost()
    }

    func attach(_ model: ToolPanelModel) {
        model.attach(tab, viewer, host)
    }
}
