import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/WindowsCertificates.cs for the part the shell needs. A certificate that opens a
// file encrypted for recipients is a Security object, which Linux has not got, so the shell holds only what the password
// overlay shows and leaves the keys to the platform.

/// An identity the person can open a file with.
public struct CertificateChoice: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let issuer: String
    public let expires: Date
    public let isValidNow: Bool

    public init(id: String, name: String, issuer: String, expires: Date, isValidNow: Bool) {
        self.id = id
        self.name = name
        self.issuer = issuer
        self.expires = expires
        self.isValidNow = isValidNow
    }
}

extension CertificateChoice {
    /// The subject stands in for a certificate that names no common name, organisation or e-mail.
    public init(_ certificate: X509Certificate, now: Date = Date()) {
        let from = Double(certificate.notBefore.unixSeconds), to = Double(certificate.notAfter.unixSeconds)
        let at = now.timeIntervalSince1970
        let name = certificate.simpleName
        self.init(id: certificate.thumbprint, name: name.isEmpty ? certificate.subject : name, issuer: certificate.issuerSimpleName,
                  expires: Date(timeIntervalSince1970: to), isValidNow: from <= at && at <= to)
    }

    /// Valid ones first, then by name.
    public static func order(_ choices: [CertificateChoice]) -> [CertificateChoice] {
        choices.sorted {
            $0.isValidNow != $1.isValidNow ? $0.isValidNow : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// The identities of the keychain and what opening a file with one takes.
public protocol CertificateKeys: AnyObject {
    /// The identities whose private key the app can use.
    func choices() -> [CertificateChoice]

    /// Opens `bytes` with the private key of `choice`. Throws `PdfReadException` (certificateRequired) when the identity is
    /// not one of the recipients.
    func open(_ bytes: [UInt8], _ choice: CertificateChoice) throws -> PdfEditSession

    /// The identity with its private key, for checking the signatures of a file `open` opened. Nil when it cannot be had.
    func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate?
}
