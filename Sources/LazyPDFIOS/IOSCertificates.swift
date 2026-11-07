#if os(iOS)
import Foundation
import Security
import LazyPDFKit
import LazyPDFApp

// Follows windows/LazyPDF.App/Services/WindowsCertificates.cs. The identities are those in the app's keychain, which is
// where SecPKCS12Import puts a .p12 or .pfx the person brings (PdfDigitalId.importPfx), so importing is the only way in.

public final class IOSCertificates: CertificateKeys {
    /// What the list shows of one certificate.
    struct Entry {
        let id: String
        let name: String
        let issuer: String
        let notBefore: Date
        let notAfter: Date
    }

    public init() {}

    /// Valid ones first, then by name.
    public func choices() -> [CertificateChoice] {
        Self.choices(identities().map(\.entry), now: Date())
    }

    static func choices(_ entries: [Entry], now: Date) -> [CertificateChoice] {
        entries
            .map { CertificateChoice(id: $0.id, name: $0.name, issuer: $0.issuer, expires: $0.notAfter,
                                     isValidNow: $0.notBefore <= now && now <= $0.notAfter) }
            .sorted { a, b in
                if a.isValidNow != b.isValidNow { return a.isValidNow }
                return a.name.caseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    public func open(_ bytes: [UInt8], _ choice: CertificateChoice) throws -> PdfEditSession {
        guard let found = identities().first(where: { $0.entry.id == choice.id }) else {
            throw PdfReadException(.certificateRequired, "That certificate is not in the keychain any more.")
        }
        return try PdfEditSession.open(bytes, certificate: PdfCertificate(certificate: found.certificate, privateKey: found.key))
    }

    /// Reads a .p12 or .pfx into the keychain and gives the choice it makes. Throws when the password is wrong or the file
    /// holds no identity.
    @discardableResult
    public func importIdentity(_ pfx: [UInt8], password: String) throws -> CertificateChoice {
        let certificate = try PdfDigitalId.importPfx(pfx, password)
        guard let entry = Self.entry(certificate) else { throw CocoaError(.fileReadCorruptFile) }
        return Self.choices([entry], now: Date())[0]
    }

    private struct Identity {
        let entry: Entry
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
                  let parsed = X509Certificate([UInt8](SecCertificateCopyData(certificate) as Data)),
                  let entry = Self.entry(parsed) else { continue }
            result.append(Identity(entry: entry, certificate: certificate, key: key))
        }
        return result
    }

    private static func entry(_ certificate: X509Certificate) -> Entry? {
        let name = certificate.simpleName
        return Entry(id: certificate.thumbprint, name: name.isEmpty ? certificate.subject : name, issuer: issuerName(certificate),
                     notBefore: Date(timeIntervalSince1970: Double(certificate.notBefore.unixSeconds)),
                     notAfter: Date(timeIntervalSince1970: Double(certificate.notAfter.unixSeconds)))
    }

    // The issuer's simple name as GetNameInfo gives it: its common name, else the whole name.
    private static func issuerName(_ certificate: X509Certificate) -> String {
        let attributes = certificate.issuer.components(separatedBy: ", ")
        if let common = attributes.first(where: { $0.hasPrefix("CN=") }) { return String(common.dropFirst(3)) }
        return certificate.issuer
    }
}
#endif
