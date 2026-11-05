#if canImport(Security)
import Foundation
import Security

// Twin of windows/LazyPDF.Core/Crypt/PdfRecipient.cs: a person a public-key file is encrypted for. Builds with the
// system's Security framework only, so it is left out on Linux, as is the rest of the public-key handler.

/// A certificate, with its private key when the holder opens files. `SecCertificate` and `SecKey` stand for the
/// C#'s X509Certificate2, which carries both.
public struct PdfCertificate {
    public let certificate: SecCertificate
    public let privateKey: SecKey?

    public init(certificate: SecCertificate, privateKey: SecKey? = nil) {
        self.certificate = certificate
        self.privateKey = privateKey
    }
}

/// `canChangeEncryption` is bit 2 of the recipient's permissions (ISO 32000-1 7.6.4.3, table 24): this
/// recipient may change or remove the encryption, the counterpart of the owner password.
public struct PdfRecipient {
    public var certificate: PdfCertificate
    public var permissions: PdfPermissions
    public var canChangeEncryption: Bool

    public init(_ certificate: PdfCertificate, permissions: PdfPermissions = .all, canChangeEncryption: Bool = false) {
        self.certificate = certificate
        self.permissions = permissions
        self.canChangeEncryption = canChangeEncryption
    }
}
#endif
