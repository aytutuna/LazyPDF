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

    /// An identity of the Signatures layer (`PdfDigitalId.importPfx`): its certificate, its key and what keeps the key
    /// usable. Nil when the certificate does not read as a system certificate.
    public init?(_ certificate: X509Certificate) {
        guard let sec = SecCertificateCreateWithData(nil, Data(certificate.rawData) as CFData) else { return nil }
        self.init(certificate: sec, privateKey: certificate.privateKey, keyHolder: certificate.keyHolder)
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

    /// Whether a file can be encrypted for `certificate`: it has an RSA key, and its key usage, if it states one,
    /// allows enciphering; or a P-256 or P-384 key whose usage, if stated, allows key agreement.
    public static func canProtect(_ certificate: PdfCertificate) -> Bool {
        guard let key = SecCertificateCopyKey(certificate.certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let parsed = X509Certificate([UInt8](SecCertificateCopyData(certificate.certificate) as Data))
        else { return false }
        let usage = (try? parsed.keyUsage()) ?? nil
        let type = (attributes[kSecAttrKeyType] as? String) ?? ""
        if type == kSecAttrKeyTypeRSA as String {
            guard let usage else { return true }
            return !usage.isDisjoint(with: [.keyEncipherment, .dataEncipherment])
        }
        if type == kSecAttrKeyTypeECSECPrimeRandom as String {
            guard [256, 384].contains(attributes[kSecAttrKeySizeInBits] as? Int) else { return false }
            return usage?.contains(.keyAgreement) ?? true
        }
        return false
    }
}
#endif
