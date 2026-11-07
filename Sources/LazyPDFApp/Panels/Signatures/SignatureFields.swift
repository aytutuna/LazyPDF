import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Signatures/SignatureFields.cs and SignedVersion.cs.

enum SignatureFields {
    /// The page and box, in user space, of the first widget of each signature field of the file, by the field's full name.
    static func locate(_ file: [UInt8], _ password: String?) throws -> [String: (page: Int, rect: PdfRect)] {
        let document = try PdfDocument.open(file, password: password)
        var found: [String: (page: Int, rect: PdfRect)] = [:]
        for field in PdfForm.read(document).fields where field.kind == .signature {
            if let widget = field.widgets.first, found[field.name] == nil { found[field.name] = (widget.pageIndex, widget.rect) }
        }
        return found
    }
}

enum SignedVersion {
    /// The file as it was when `report`'s signature closed it; nil when that revision is not found.
    static func of(_ file: [UInt8], _ report: SignatureReport) -> [UInt8]? {
        PdfRevisions.list(file).first { $0.number == report.revision }.map { PdfRevisions.extract(file, $0) }
    }
}
