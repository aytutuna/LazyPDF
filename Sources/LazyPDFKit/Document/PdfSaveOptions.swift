import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfSaveOptions.cs: how `PdfDocument.saveRewrite` writes.
// `useObjectStreams` packs the plain objects into object streams and lists them in a cross-reference stream
// (PDF 1.5). `security` encrypts the new file with that handler; nil leaves it open, so passing nil for an
// encrypted file removes the encryption, and passing the document's own `PdfDocument.security` keeps it.
// `documentId` is the first string of the new /ID (16 random bytes when nil); a handler made by
// `PdfSecurity.create` for the 128-bit strength must have been given the same one.

public struct PdfSaveOptions {
    public var useObjectStreams: Bool
    public var security: PdfSecurity?
    public var documentId: [UInt8]?

    public init(useObjectStreams: Bool = false, security: PdfSecurity? = nil, documentId: [UInt8]? = nil) {
        self.useObjectStreams = useObjectStreams
        self.security = security
        self.documentId = documentId
    }
}
