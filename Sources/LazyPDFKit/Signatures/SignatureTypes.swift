import Foundation

// Twin of windows/LazyPDF.Core/Signatures/SignatureTypes.cs: the vocabulary of signing and verifying. The C# types
// of System.Security.Cryptography have no place here (LazyPDFKit imports Foundation alone): HashAlgorithmName is the
// enum below and X509Certificate2 is X509Certificate (X509Certificate.swift), which reads the certificate itself and
// holds a SecKey for its private key on Apple platforms.

/// What a person should make of a signature.
public enum SignatureVerdict {
    /// Intact, the signer is trusted, and the file is unchanged or changed only as the signer allowed.
    case valid
    /// Intact, but the signer's certificate does not lead to a trusted root, was not valid at signing time or is revoked.
    case validButUntrusted
    /// The signed part is intact, but the file was changed afterwards in ways that are not allowed.
    case changedAfterSigning
    /// The digest or the signature does not match, or the signature does not cover the file as it must.
    case broken
    /// It could not be checked: a format or algorithm Lazy PDF does not read, or a file it cannot make sense of.
    case unknown
}

public enum SignatureKind {
    case approval
    /// The first signature, with a /DocMDP rule on what may change afterwards.
    case certification
    /// A time stamp over the document (ETSI.RFC3161) with no signer.
    case documentTimestamp
}

/// The signature format: /SubFilter adbe.pkcs7.detached or ETSI.CAdES.detached.
public enum SignatureFormat {
    case pkcs7Detached
    case cadesDetached
}

/// The /DocMDP access permission (ISO 32000-1 12.8.2.2.2) a certification signature grants.
public enum CertificationLevel: Int {
    case none = 0
    case noChanges = 1
    case formFill = 2
    case annotate = 3
}

/// PAdES baseline level of a CAdES signature (ETSI EN 319 142-1).
public enum PadesLevel: Int, Comparable {
    /// Not a CAdES signature, or one that does not reach B-B.
    case none
    case b
    case t
    case lt
    case lta

    public static func < (a: PadesLevel, b: PadesLevel) -> Bool { a.rawValue < b.rawValue }
}

public enum SignatureProblem {
    case unsupportedFormat
    case badByteRange
    case digestMismatch
    case badSignature
    case noCertificate
    case untrustedSigner
    case certificateNotValid
    case certificateRevoked
    case changedAfterSigning
    case damagedStructure
    case timestampInvalid
    case weakDigest
}

/// The digests that sign and the one a time stamp or a signature algorithm names (the C# HashAlgorithmName).
public enum HashAlgorithmName: String {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha384 = "SHA384"
    case sha512 = "SHA512"
}

/// Signs a digest for a key that is not in this process: a smart card, a token, a remote service. `hash` is the
/// digest to sign and `algorithm` the one it was made with. Returns an RSA PKCS#1 v1.5 signature, or an ECDSA
/// signature as r followed by s (IEEE P1363).
public typealias PdfHashSigner = (_ hash: [UInt8], _ algorithm: HashAlgorithmName) throws -> [UInt8]

/// Posting and fetching bytes, which the engine never does itself: time stamps, OCSP, CRLs, issuer certificates.
public protocol SignatureTransport: AnyObject {
    /// The response body of a POST, or nil when the request failed.
    func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]?

    /// The body of a GET, or nil when the request failed.
    func get(_ url: String) -> [UInt8]?
}

/// Where to get an RFC 3161 time stamp.
public struct TimestampSettings {
    public var transport: SignatureTransport
    public var url: String?
    public var digest: HashAlgorithmName = .sha256

    public init(_ transport: SignatureTransport, url: String? = nil) {
        self.transport = transport
        self.url = url
    }
}

/// What the signer of a field is bound to when a later signature fills it in (ISO 32000-1 12.7.4.5).
public enum FieldLockAction: String {
    case all = "All"
    case include = "Include"
    case exclude = "Exclude"
}

/// Fields locked once this signature is applied. `fields` are field names.
public struct FieldLock {
    public var action: FieldLockAction
    public var fields: [String]

    public init(_ action: FieldLockAction, _ fields: [String]) {
        self.action = action
        self.fields = fields
    }
}

/// What changed since a signature, by kind (see `SignatureText.describe`).
public enum SignatureChangeKind {
    case formFill
    case signature
    case validationData
    case comment
    case metadata
    case pageContent
    case pageStructure
    case form
    case other
    /// What follows the signed bytes cannot be read exactly, so nothing about it can be judged.
    case unreadable
}

/// One difference between the signed revision and a later one. `page` is 0-based, -1 when no page is involved.
public struct SignatureChange {
    public var kind: SignatureChangeKind
    public var object: Int
    public var page: Int
    public var field: String?
    public var allowed: Bool

    public init(_ kind: SignatureChangeKind, _ object: Int, _ page: Int, _ field: String?, _ allowed: Bool) {
        self.kind = kind
        self.object = object
        self.page = page
        self.field = field
        self.allowed = allowed
    }
}

/// The differences between the signed revision and the file as it is.
public struct SignatureChangeReport {
    public var changes: [SignatureChange]
    public var revisionsAfter: Int

    public init(_ changes: [SignatureChange], _ revisionsAfter: Int) {
        self.changes = changes
        self.revisionsAfter = revisionsAfter
    }

    public static let none = SignatureChangeReport([], 0)

    public var isEmpty: Bool { changes.isEmpty }

    public var allAllowed: Bool { changes.allSatisfy { $0.allowed } }

    public var notAllowed: [SignatureChange] { changes.filter { !$0.allowed } }
}

/// One signature (or document time stamp) found in a file and what is known of it.
public struct SignatureReport {
    public var index = 0

    /// The form field the signature sits in, nil when no field of the current file holds it.
    public var fieldName: String?

    public var kind = SignatureKind.approval

    public var subFilter = ""
    public var verdict = SignatureVerdict.valid
    public var problems: [SignatureProblem] = []

    /// The signer's common name; the /Name entry when the certificate has none. Nil for a time stamp.
    public var signerName: String?

    public var certificate: X509Certificate?
    public var reason: String?
    public var location: String?

    /// When the signer says it was signed (the signing-time attribute, else /M). Not proof of anything without a time stamp.
    public var signingTime: DateTimeOffset?

    /// The time of a valid RFC 3161 token, in the signature or, for a document time stamp, the token itself.
    public var timestampTime: DateTimeOffset?

    /// The time used to judge the certificates: the time stamp, else the signer's claim, else the time the caller gave.
    public var timeUsed: DateTimeOffset?

    public var certification = CertificationLevel.none
    public var level = PadesLevel.none

    /// The byte range covers the file to its end.
    public var coversWholeFile = false

    /// The revision (from 1) the signature closes; 0 when that is not known.
    public var revision = 0

    public var changes = SignatureChangeReport.none

    /// True when OCSP or CRL data from the signature or the /DSS shows no certificate of the chain revoked.
    public var revocationChecked = false

    public init() {}

    /// One plain line a person can read.
    public var sentence: String { SignatureText.sentence(self) }
}

/// What to trust when verifying.
public struct VerifyOptions {
    /// Roots (or intermediates) the caller trusts.
    public var trustAnchors: [X509Certificate] = []

    /// Also trust the roots of the system store.
    public var useSystemStore = false

    /// The time used for certificates when a signature carries no time of its own; the caller's clock.
    public var now: DateTimeOffset?

    public var password: String?

    /// For a file encrypted to recipients: the certificate of one of them, with its private key.
    public var certificate: X509Certificate?

    public init() {}
}
