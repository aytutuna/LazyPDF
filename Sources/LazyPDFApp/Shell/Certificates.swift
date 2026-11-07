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

extension CertificateKeys {
    public func verifyCertificate(_ choice: CertificateChoice) -> X509Certificate? { nil }
}
