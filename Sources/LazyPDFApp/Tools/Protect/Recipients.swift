import Foundation
import LazyPDFKit
#if canImport(Security)
import Security
#endif

// Follows windows/LazyPDF.App/Tools/Protect/Recipients.cs.

/// A certificate the file is locked for. Whoever holds its private key here may also change the protection later.
public struct Recipient: Identifiable {
    public let thumbprint: String
    public let name: String
    public let issuer: String
    public let notAfter: Date
    public let hasPrivateKey: Bool
    public let der: [UInt8]
    #if canImport(Security)
    let certificate: PdfCertificate
    #endif

    public var id: String { thumbprint }

    public func expired(now: Date = Date()) -> Bool { notAfter < now }

    public func details(now: Date = Date()) -> String {
        let date = notAfter.formatted(date: .numeric, time: .omitted)
        return expired(now: now) ? L10n.t("{0}, expired {1}", issuer, date) : L10n.t("{0}, valid until {1}", issuer, date)
    }
}

#if canImport(Security)
extension Recipient {
    init?(_ certificate: PdfCertificate) {
        let der = [UInt8](SecCertificateCopyData(certificate.certificate) as Data)
        guard let x509 = X509Certificate(der), PdfRecipient.canProtect(certificate) else { return nil }
        thumbprint = x509.thumbprint
        name = x509.simpleName.isEmpty ? x509.subject : x509.simpleName
        issuer = x509.issuerSimpleName
        notAfter = PanelDates.date(x509.notAfter)
        hasPrivateKey = certificate.privateKey != nil
        self.der = der
        self.certificate = certificate
    }

    public func toPdfRecipient(_ allowed: PdfPermissions) -> PdfRecipient {
        PdfRecipient(certificate, permissions: allowed, canChangeEncryption: hasPrivateKey)
    }
}

public enum RecipientSource {
    /// Reads a certificate file (DER or PEM). Nil when it is not one, or its key cannot lock a PDF.
    public static func fromFile(_ bytes: [UInt8]) -> Recipient? {
        guard let der = derOf(bytes), let sec = SecCertificateCreateWithData(nil, Data(der) as CFData) else { return nil }
        return Recipient(withStoredKey(sec))
    }

    /// Your own certificates and the ones kept for other people, RSA keys that can encrypt only, valid ones first.
    public static func fromStore() -> [Recipient] {
        var found: [String: Recipient] = [:]
        for sec in identities().map(\.certificate) + stored() {
            if let recipient = Recipient(withStoredKey(sec)), found[recipient.thumbprint] == nil { found[recipient.thumbprint] = recipient }
        }
        let now = Date()
        return found.values.sorted {
            $0.expired(now: now) != $1.expired(now: now)
                ? !$0.expired(now: now) : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // A certificate file carries no key; when the same certificate is in the person's keychain with its identity the key is there.
    private static func withStoredKey(_ certificate: SecCertificate) -> PdfCertificate {
        let data = SecCertificateCopyData(certificate) as Data
        if let own = identities().first(where: { SecCertificateCopyData($0.certificate) as Data == data }) { return own }
        return PdfCertificate(certificate: certificate)
    }

    private static func identities() -> [PdfCertificate] {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let list = result as? [SecIdentity] else { return [] }
        return list.compactMap { identity in
            var certificate: SecCertificate?
            var key: SecKey?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
            _ = SecIdentityCopyPrivateKey(identity, &key)
            return PdfCertificate(certificate: certificate, privateKey: key)
        }
    }

    private static func stored() -> [SecCertificate] {
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return result as? [SecCertificate] ?? []
    }

    // A PEM file wraps the same bytes in base64 between two lines.
    private static func derOf(_ bytes: [UInt8]) -> [UInt8]? {
        guard let text = String(bytes: bytes, encoding: .utf8), text.contains("-----BEGIN") else { return bytes }
        let body = text.split(whereSeparator: { $0.isNewline }).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body).map { [UInt8]($0) }
    }
}

#endif
