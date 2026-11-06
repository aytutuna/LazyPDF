#if canImport(Security)
import Foundation
import Security

// Twin of windows/LazyPDF.Core/Crypt/PdfRecipient.cs: a person a public-key file is encrypted for. Builds with the
// system's Security framework only, so it is left out on Linux, as is the rest of the public-key handler.

/// A certificate, with its private key when the holder opens files. `SecCertificate` and `SecKey` stand for the
/// C#'s X509Certificate2, which carries both.
public struct PdfCertificate {
    public let certificate: SecCertificate
    private let key: SecKey?

    /// The key, after what keeps it usable (the keychain it was imported into, see `X509Certificate.keyHolder`) has been
    /// told it is wanted.
    public var privateKey: SecKey? {
        keyHolder?.prepare()
        return key
    }

    /// Kept so that it lives as long as the certificate does.
    let keyHolder: KeyHolder?

    public init(certificate: SecCertificate, privateKey: SecKey? = nil) {
        self.init(certificate: certificate, privateKey: privateKey, keyHolder: nil)
    }

    init(certificate: SecCertificate, privateKey: SecKey?, keyHolder: KeyHolder?) {
        self.certificate = certificate
        self.key = privateKey
        self.keyHolder = keyHolder
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
