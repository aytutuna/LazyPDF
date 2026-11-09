import Foundation
import LazyPDFKit

// The window's side of ToolHost.openSigning, takeSigningField, isDocumentBusy and verifyCertificate
// (windows/LazyPDF.App/Tools/IToolHost.cs).

extension AppViewModel {
    public func openSigning(_ field: String) {
        signingField = field
        if activeToolId != "certificates" { selectTool("certificates") }
    }

    public func takeSigningField() -> String? {
        defer { signingField = nil }
        return signingField
    }

    public var isDocumentBusy: Bool { isBusy || MarkWork.shared.running }

    public func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate? {
        certificates.verifyCertificate(choice)
    }
}
