#if os(macOS)
import Foundation
import Security
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/WindowsCertificates.cs, with the keychain for the Windows store. The identities
// are those of the app's keychain; a .p12 or .pfx the person picks is read by the engine (PdfDigitalId.importPfx) and
// kept there as well, and stays usable in this run even when the keychain refuses it.

final class MacCertificates: CertificateKeys {
    private struct Entry {
        let x509: X509Certificate
        let identity: PdfCertificate
    }

    private let lock = NSLock()
    private var imported: [String: Entry] = [:]

    func choices() -> [CertificateChoice] {
        var found = keychainEntries()
        lock.lock()
        for (id, entry) in imported where !found.contains(where: { $0.x509.thumbprint == id }) { found.append(entry) }
        lock.unlock()
        return Self.order(found.map { Self.choice($0.x509) })
    }

    func open(_ bytes: [UInt8], _ choice: CertificateChoice) throws -> PdfEditSession {
        lock.lock()
        let held = imported[choice.id]
        lock.unlock()
        guard let entry = held ?? keychainEntries().first(where: { $0.x509.thumbprint == choice.id }) else {
            throw PdfReadException(.certificateRequired, "The certificate is not in the keychain.")
        }
        return try PdfEditSession.open(bytes, certificate: entry.identity)
    }

    /// Reads the identity of a .p12 or .pfx file. Throws when the password is wrong or the file holds no key.
    /// `keep` also adds the key and certificate to the keychain, which tests leave out.
    func importIdentity(_ pfx: [UInt8], password: String, keep: Bool = true) throws -> CertificateChoice {
        let x509 = try PdfDigitalId.importPfx(pfx, password)
        guard let identity = PdfCertificate(x509) else {
            throw InvalidDataException("The PFX file holds no certificate the system can read.")
        }
        if keep { addToKeychain(identity) }
        lock.lock()
        imported[x509.thumbprint] = Entry(x509: x509, identity: identity)
        lock.unlock()
        return Self.choice(x509)
    }

    static func choice(_ certificate: X509Certificate, now: Date = Date()) -> CertificateChoice {
        let from = Double(certificate.notBefore.unixSeconds), to = Double(certificate.notAfter.unixSeconds)
        let at = now.timeIntervalSince1970
        return CertificateChoice(id: certificate.thumbprint, name: certificate.simpleName, issuer: certificate.issuerSimpleName,
                                 expires: Date(timeIntervalSince1970: to), isValidNow: from <= at && at <= to)
    }

    /// Valid ones first, then by name.
    static func order(_ choices: [CertificateChoice]) -> [CertificateChoice] {
        choices.sorted {
            $0.isValidNow != $1.isValidNow ? $0.isValidNow : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // Only identities whose key can sign or decrypt are of use; the others would fail when picked.
    private func keychainEntries() -> [Entry] {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let identities = result as? [SecIdentity] else { return [] }
        return identities.compactMap { identity in
            var certificate: SecCertificate?
            var key: SecKey?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
                  SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key, Self.canUse(key),
                  let x509 = X509Certificate([UInt8](SecCertificateCopyData(certificate) as Data)) else { return nil }
            return Entry(x509: x509, identity: PdfCertificate(certificate: certificate, privateKey: key))
        }
    }

    private static func canUse(_ key: SecKey) -> Bool {
        SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256)
            || SecKeyIsAlgorithmSupported(key, .sign, .ecdsaSignatureMessageX962SHA256)
            || SecKeyIsAlgorithmSupported(key, .decrypt, .rsaEncryptionPKCS1)
    }

    // A key that is already there is not an error, and one the keychain refuses leaves the identity in memory only.
    private func addToKeychain(_ identity: PdfCertificate) {
        if let key = identity.privateKey {
            SecItemAdd([kSecClass as String: kSecClassKey, kSecValueRef as String: key] as CFDictionary, nil)
        }
        SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: identity.certificate] as CFDictionary, nil)
    }
}
#endif
