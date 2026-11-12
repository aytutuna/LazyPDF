#if os(iOS)
import Foundation
import Security
import LazyPDFKit
import LazyPDFApp

// Follows windows/LazyPDF.App/Services/WindowsCertificates.cs. The identities are those in the app's keychain, which is
// where a .p12 or .pfx the person brings is stored (SecPKCS12Import only reads it on iOS, SecItemAdd keeps it), so
// importing is the only way in.

public final class IOSCertificates: CertificateKeys {
    public init() {}

    public func choices() -> [CertificateChoice] {
        CertificateChoice.order(identities().map { CertificateChoice($0.x509) })
    }

    public func open(_ bytes: [UInt8], _ choice: CertificateChoice) throws -> PdfEditSession {
        guard let found = identities().first(where: { $0.x509.thumbprint == choice.id }) else {
            throw PdfReadException(.certificateRequired, "That certificate is not in the keychain any more.")
        }
        return try PdfEditSession.open(bytes, certificate: PdfCertificate(certificate: found.certificate, privateKey: found.key))
    }

    public func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate? {
        identities().first(where: { $0.x509.thumbprint == choice.id })?.x509
    }

    /// Reads a .p12 or .pfx into the keychain and gives the choice it makes. Throws when the password is wrong or the file
    /// holds no identity.
    @discardableResult
    public func importIdentity(_ pfx: [UInt8], password: String) throws -> CertificateChoice {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password]
        guard SecPKCS12Import(Data(pfx) as CFData, options as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]], let found = list.first?[kSecImportItemIdentity as String],
              CFGetTypeID(found as AnyObject) == SecIdentityGetTypeID() else { throw CocoaError(.fileReadCorruptFile) }
        let identity = found as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              let parsed = X509Certificate([UInt8](SecCertificateCopyData(certificate) as Data)) else { throw CocoaError(.fileReadCorruptFile) }
        let status = SecItemAdd([kSecValueRef as String: identity] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw CocoaError(.fileWriteUnknown) }
        guard identities().contains(where: { $0.x509.thumbprint == parsed.thumbprint }) else { throw CocoaError(.fileWriteUnknown) }
        return CertificateChoice(parsed)
    }

    /// Takes an imported identity, its certificate and its key, out of the keychain. True when it is gone.
    public func remove(_ choice: CertificateChoice) -> Bool {
        guard let found = identities().first(where: { $0.x509.thumbprint == choice.id }) else { return true }
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecValueRef as String: found.identity]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private struct Identity {
        let identity: SecIdentity
        let x509: X509Certificate
        let certificate: SecCertificate
        let key: SecKey
    }

    private func identities() -> [Identity] {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let list = found as? [Any] else { return [] }
        var result: [Identity] = []
        for item in list {
            // The query asks for identities only, and Swift checks no CoreFoundation type on a cast.
            let identity = item as! SecIdentity
            var certificate: SecCertificate?
            var key: SecKey?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
                  let parsed = X509Certificate([UInt8](SecCertificateCopyData(certificate) as Data)) else { continue }
            parsed.privateKey = key
            result.append(Identity(identity: identity, x509: parsed, certificate: certificate, key: key))
        }
        return result
    }
}
#endif
