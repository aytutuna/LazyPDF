import Foundation

// Twin of windows/LazyPDF.Core/Structure/DocumentFacts.cs: what the Properties panel shows about an open file.

public enum FormKind {
    case none, acroForm, xfa
}

/// What the Properties panel shows about an open file. `permissions` is nil for a file that is not encrypted. The page
/// size is the first page's, as shown (rotation and user unit applied), in points.
public struct DocumentFacts {
    public let version: String
    public let fileSize: Int
    public let pageCount: Int
    public let firstPageWidth: Double
    public let firstPageHeight: Double
    public let metadata: DocumentMetadata
    public let language: String?
    public let isTagged: Bool
    public let isLinearized: Bool
    public let isEncrypted: Bool
    public let permissions: PdfPermissions?
    public let isSigned: Bool
    public let isCertified: Bool
    public let form: FormKind
    public let hasJavaScript: Bool
    public let hasBookmarks: Bool
    public let isPortfolio: Bool
    public let attachmentCount: Int
    public let layerCount: Int
    public let pdfAPart: Int?
    public let pdfAConformance: String?
    public let repairCount: Int

    public static func read(_ document: PdfDocument) -> DocumentFacts {
        let first = document.pages.count > 0 ? PageGeometry(document.pages[0]) : nil
        let form = document.dict(document.catalog, "AcroForm")
        let kind: FormKind
        if document.hasXfa {
            kind = .xfa
        } else if let fields = document.array(form, "Fields"), !fields.items.isEmpty {
            kind = .acroForm
        } else {
            kind = .none
        }
        return DocumentFacts(
            version: document.version, fileSize: document.length, pageCount: document.pages.count,
            firstPageWidth: first?.width ?? 0, firstPageHeight: first?.height ?? 0,
            metadata: DocumentMetadata.read(document), language: PdfText.read(document, document.catalog, "Lang"),
            isTagged: document.isTagged, isLinearized: document.isLinearized, isEncrypted: document.isEncrypted,
            permissions: document.security?.permissions, isSigned: document.isSigned, isCertified: document.isCertified, form: kind,
            hasJavaScript: PdfActions.hasJavaScript(document), hasBookmarks: document.dict(document.catalog, "Outlines")?["First"] != nil,
            isPortfolio: document.dict(document.catalog, "Collection") != nil,
            attachmentCount: PdfAttachments.list(document).count, layerCount: PdfLayers.read(document).layers.count,
            pdfAPart: document.pdfAPart, pdfAConformance: document.pdfAConformance, repairCount: document.repairs.count)
    }
}
