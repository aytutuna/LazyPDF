import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Signatures/SignatureFields.cs and SignedVersion.cs.

enum SignatureFields {
    /// The page and box, in user space, of the first widget of each signature field of the file, by the field's full name.
    static func locate(_ file: [UInt8], _ password: String?, _ certificate: X509Certificate? = nil) throws -> [String: (page: Int, rect: PdfRect)] {
        let document = try open(file, password, certificate)
        var found: [String: (page: Int, rect: PdfRect)] = [:]
        for field in PdfForm.read(document).fields where field.kind == .signature {
            // A widget no page lists has page -1; one that is on a page is the better place to show.
            if let widget = field.widgets.first(where: { $0.pageIndex >= 0 }) ?? field.widgets.first, found[field.name] == nil {
                found[field.name] = (widget.pageIndex, widget.rect)
            }
        }
        return found
    }

    private static func open(_ file: [UInt8], _ password: String?, _ certificate: X509Certificate?) throws -> PdfDocument {
        #if canImport(Security)
        if let certificate, let held = PdfCertificate(certificate) { return try PdfDocument.open(file, certificate: held) }
        #endif
        return try PdfDocument.open(file, password: password)
    }
}

enum SignedVersion {
    /// The file as it was when `report`'s signature closed it; nil when that revision is not found.
    static func of(_ file: [UInt8], _ report: SignatureReport) -> [UInt8]? {
        PdfRevisions.list(file).first { $0.number == report.revision }.map { PdfRevisions.extract(file, $0) }
    }
}
