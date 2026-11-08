import Foundation
import LazyPDFKit

// Follows OptimizeJob.Open and NeedsOwner of windows/LazyPDF.App/Tools/Optimize/OptimizeJob.cs: a tool that works off the main
// actor opens its own copy of the file's bytes, the way the tab opened them.

public enum ToolDocuments {
    /// `certificate` is the identity a file for recipients was opened with, from `ToolHost.verifyCertificate`.
    public static func open(_ file: [UInt8], password: String?, certificate: X509Certificate?) throws -> PdfDocument {
        #if canImport(Security)
        if let certificate, let held = PdfCertificate(certificate) { return try PdfDocument.open(file, certificate: held) }
        #endif
        return try PdfDocument.open(file, password: password)
    }

    /// True when the file restricts what may be done to it and was not opened with the owner's rights, so a rewrite is
    /// refused.
    public static func needsOwner(_ document: PdfDocument) -> Bool {
        guard let security = document.security else { return false }
        return !security.openedAsOwner && security.permissions != .all
    }
}
