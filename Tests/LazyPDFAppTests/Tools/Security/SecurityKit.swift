import Foundation
import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// What the tests of the security tools share: a window that keeps the password and certificate a new tab was opened with, and
// the pickers and exporter of a platform, which the tools reach through ToolHost.

@MainActor
final class SecurityHost: ToolHost, ToolFilePicker, ToolFileExporter {
    var problems: [Problem] = []
    var notices: [(title: String, text: String)] = []
    var lastNoticeAction: NoticeAction?
    var statuses: [String] = []
    var openedNew: [(pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?)] = []
    var busyTexts: [String] = []
    var token = CancelToken()
    var identities: [CertificateChoice] = []
    var keys: [String: X509Certificate] = [:]
    var picked: [ToolFile] = []
    var exportAnswers = true
    var pendingMark: SelectionMark?
    var exported: [(name: String, bytes: [UInt8])] = []
    var exportedUrls: [URL] = []
    var signingField: String?

    func takeSelectionMark() -> SelectionMark? {
        defer { pendingMark = nil }
        return pendingMark
    }

    var filePicker: ToolFilePicker { self }
    var fileExporter: ToolFileExporter { self }

    func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws {
        busyTexts.append(text)
        do {
            try await work(token)
        } catch is CancellationError {
            setStatus("Cancelled.")
        }
    }

    func setBusyText(_ text: String) {}
    func showProblem(_ problem: Problem) { problems.append(problem) }
    func showNotice(_ title: String, _ text: String, _ action: NoticeAction?) {
        notices.append((title, text))
        lastNoticeAction = action
    }
    func setStatus(_ sentence: String) { statuses.append(sentence) }
    func open(_ url: URL, access: FileAccess?) async {}

    func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async {
        openedNew.append((pdf, title, password, certificate))
    }

    func tryReload(_ tab: DocumentTab) async -> Bool { true }

    func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate? { keys[choice.id] }
    func certificateChoices() -> [CertificateChoice] { identities }
    func takeSigningField() -> String? {
        defer { signingField = nil }
        return signingField
    }

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] {
        defer { picked = [] }
        return picked
    }

    func pickFolder() async -> ToolFile? { nil }

    func export(_ files: [URL]) async -> ToolExport {
        exportedUrls = files
        exported = files.map { ($0.lastPathComponent, [UInt8]((try? Data(contentsOf: $0)) ?? Data())) }
        return exportAnswers ? ToolExport(saved: files) : ToolExport()
    }
}

/// A tab with a viewer and a `SecurityHost`, as ToolRig has them with the recording window.
@MainActor
struct SecurityRig {
    let tab: DocumentTab
    let viewer: PanelViewer
    let host: SecurityHost

    init(_ bytes: [UInt8]? = nil, password: String? = nil, title: String = "a.pdf") throws {
        tab = DocumentTab(session: try PdfEditSession.open(bytes ?? Pdfs.text(2), password: password), renderer: FakeRenderer(), url: nil,
                          title: title, password: password)
        viewer = PanelViewer(tab)
        host = SecurityHost()
    }

    func attach(_ model: ToolPanelModel) {
        model.attach(tab, viewer, host)
    }
}
