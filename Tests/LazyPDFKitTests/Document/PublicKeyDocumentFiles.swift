import XCTest
@testable import LazyPDFKit

// The part of windows/LazyPDF.Core.Tests/Crypt/PublicKeyFiles.cs that needs PdfDocument (Plain, Seal, Content), which
// the Crypt layer's twin (Crypt/PublicKeyFiles.swift) leaves out. `SealedPage` holds what needs no certificate, so
// that Linux has it too.

enum SealedPage {
    static let pageText = "(Sealed for recipients) Tj"

    /// A one-page file with `pageText` in its content stream.
    static func plain() -> [UInt8] {
        TestPdf()
            .obj(1, "<</Type/Catalog/Pages 2 0 R>>")
            .obj(2, "<</Type/Pages/Kids[3 0 R]/Count 1>>")
            .obj(3, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>")
            .stream(4, "", "BT /F1 12 Tf 20 100 Td " + pageText + " ET")
            .obj(5, "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
            .obj(6, "<</Title(Sealed title)>>")
            .finish("/Root 1 0 R /Info 6 0 R")
    }

    static func content(_ document: PdfDocument) -> String {
        Latin1.string(document.pages[0].contents())
    }
}

#if canImport(Security)
extension PublicKeyFiles {
    static let pageText = SealedPage.pageText

    static func plain() -> [UInt8] { SealedPage.plain() }

    static func seal(_ recipients: [PdfRecipient], _ strength: PdfCryptStrength = .aes256, objectStreams: Bool = false) throws -> [UInt8] {
        try PdfDocument.open(plain()).saveRewrite(PdfSaveOptions(useObjectStreams: objectStreams,
                                                                 security: try PdfSecurity.createPublicKey(recipients, strength)))
    }

    static func seal(_ certificate: PdfCertificate, _ strength: PdfCryptStrength = .aes256) throws -> [UInt8] {
        try seal([PdfRecipient(certificate)], strength)
    }

    static func content(_ document: PdfDocument) -> String { SealedPage.content(document) }
}
#endif
