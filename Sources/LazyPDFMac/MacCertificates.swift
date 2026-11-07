#if os(macOS)
import Foundation
import Security
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/WindowsCertificates.cs, with the keychain for the Windows store. The identities
// are those of the app's keychain; a .p12 or .pfx the person picks is read by the engine (PdfDigitalId.importPfx) and
// imported into the keychain as well. It stays usable in this run when the keychain refuses it, and `kept` says so.

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
        guard let identity = certificate(for: choice) else {
            throw PdfReadException(.certificateRequired, "The certificate is not in the keychain.")
        }
        return try PdfEditSession.open(bytes, certificate: identity)
    }

    /// What reading text, making a display copy and checking signatures need for a tab opened with `choice`.
    func certificate(for choice: CertificateChoice) -> PdfCertificate? {
        lock.lock()
        let held = imported[choice.id]
        lock.unlock()
        return (held ?? keychainEntries().first(where: { $0.x509.thumbprint == choice.id }))?.identity
    }

    /// Reads the identity of a .p12 or .pfx file. Throws when the password is wrong or the file holds no key.
    /// `keep` also imports it into the keychain, which tests leave out; `kept` is false when the keychain refused.
    func importIdentity(_ pfx: [UInt8], password: String, keep: Bool = true) throws -> (choice: CertificateChoice, kept: Bool) {
        let x509 = try PdfDigitalId.importPfx(pfx, password)
        guard let identity = PdfCertificate(x509) else {
            throw InvalidDataException("The PFX file holds no certificate the system can read.")
        }
        // The engine's own import may be in memory or in a keychain that goes with the process; this one is for good.
        let kept = keep && Self.addToKeychain(pfx, password)
        lock.lock()
        imported[x509.thumbprint] = Entry(x509: x509, identity: identity)
        lock.unlock()
        return (Self.choice(x509), kept)
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

    static func canUse(_ key: SecKey) -> Bool {
        let attributes = SecKeyCopyAttributes(key) as? [String: Any]
        return (attributes?[kSecAttrKeyClass as String] as? String) == (kSecAttrKeyClassPrivate as String)
            && (SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256)
            || SecKeyIsAlgorithmSupported(key, .sign, .ecdsaSignatureMessageX962SHA256)
            || SecKeyIsAlgorithmSupported(key, .decrypt, .rsaEncryptionPKCS1))
    }

    // SecPKCS12Import adds to the default keychain unless it is asked for memory only; an identity that is already
    // there answers with a duplicate item, which is not a failure.
    private static func addToKeychain(_ pfx: [UInt8], _ password: String) -> Bool {
        var items: CFArray?
        let status = SecPKCS12Import(Data(pfx) as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        return status == errSecSuccess || status == errSecDuplicateItem
    }
}
#endif
