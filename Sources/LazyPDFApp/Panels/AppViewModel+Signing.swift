import Foundation
import LazyPDFKit

// The window's side of ToolHost.openSigning, takeSigningField, markSelection, isDocumentBusy and verifyCertificate
// (windows/LazyPDF.App/Tools/IToolHost.cs).

extension AppViewModel {
    public func openTool(_ id: String) {
        if activeToolId != id { selectTool(id) }
    }

    public func openSigning(_ field: String) {
        signingField = field
        if activeToolId != "certificates" { selectTool("certificates") }
    }

    public func takeSigningField() -> String? {
        defer { signingField = nil }
        return signingField
    }

    public func markSelection(_ mark: SelectionMark) {
        let id = mark == .redact ? "redact" : "comment"
        if activeToolId == id, let markHandler {
            Task { await markHandler(mark) }
            return
        }
        pendingMark = mark
        if activeToolId != id { selectTool(id) }
        if activeToolId != id { pendingMark = nil }
    }

    public func takeSelectionMark() -> SelectionMark? {
        defer { pendingMark = nil }
        return pendingMark
    }

    public func takesSelectionMarks(_ handler: (@MainActor (SelectionMark) async -> Void)?) {
        markHandler = handler
    }

    public var isDocumentBusy: Bool { isBusy || MarkWork.shared.running }

    public func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate? {
        certificates.verifyCertificate(choice)
    }

    public func certificateChoices() -> [CertificateChoice] {
        certificates.choices()
    }
}
