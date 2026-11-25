import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Pages/CopyRules.cs: pages copied into a new file leave the source's password and
// permissions behind, so the source decides whether that may happen.

@MainActor
public enum CopyRules {
    /// The file limits what its readers may do and was not opened with the owner's rights.
    public static func locked(_ document: PdfDocument) -> Bool {
        ToolDocuments.needsOwner(document)
    }

    /// True, with the reason shown, when pages may not be copied out of `document`.
    public static func refused(_ document: PdfDocument, _ host: ToolHost) -> Bool {
        guard locked(document) else { return false }
        host.showProblem(Problem(L10n.t("File is protected"),
                                 L10n.t("Its owner limits what may be done with it. Open it with the owner password to copy pages out.")))
        return true
    }

    public static var unprotected: String { L10n.t("The copies are not password protected.") }

    public static func noteUnprotected(_ document: PdfDocument, _ host: ToolHost) {
        if document.isEncrypted { host.showNotice(L10n.t("Copy is not protected"), unprotected, nil) }
    }
}
