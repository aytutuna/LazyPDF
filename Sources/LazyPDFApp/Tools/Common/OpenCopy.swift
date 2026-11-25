import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Standards/OpenCopy.cs. Standards and Accessibility share it, and so do the tools that
// convert.

public enum OpenCopy {
    /// A second reading of the tab's file, for work that runs off the main actor and must not touch the open document. The
    /// bytes are taken now, so what the job reads is the file as it is at this moment.
    @MainActor
    public static func of(_ tab: DocumentTab, _ host: ToolHost) -> @Sendable () throws -> PdfDocument {
        let file = tab.session.current
        let password = tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        return { try ToolDocuments.open(file, password: password, certificate: certificate) }
    }
}
