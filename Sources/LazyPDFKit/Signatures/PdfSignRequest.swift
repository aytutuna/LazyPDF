import Foundation

// Twin of windows/LazyPDF.Core/Signatures/PdfSignRequest.cs: a signature to apply: with whom, where, and in which
// format. `time` is the caller's clock. The certificate needs its private key unless `signer` signs for it.

/// What a visible signature shows: text, and a picture or ink on the left when there is one. Without a rectangle on
/// the request none of it is drawn.
public struct SignatureLook {
    /// The text, lines split at line feeds. Nil writes the signer's name, date, reason and location; empty writes none.
    public var text: String?

    public var fontFamily = "Helvetica"

    /// A picture of the signature as a JPEG; used before `image`.
    public var jpeg: [UInt8]?

    public var image: PdfRgbaImage?

    /// Strokes of a drawn signature, points in the unit square with y up. Drawn when there is no picture.
    public var ink: [[(x: Double, y: Double)]]?

    public init() {}
}

public struct PdfSignRequest {
    public var certificate: X509Certificate
    public var time: DateTimeOffset

    /// Signs the digest for a key held elsewhere; the certificate then needs no private key.
    public var signer: PdfHashSigner?

    /// Intermediate certificates to embed; the chain the system can build is used when empty.
    public var chain: [X509Certificate] = []

    public var format = SignatureFormat.cadesDetached

    /// SHA-256, SHA-384 or SHA-512.
    public var digest = HashAlgorithmName.sha256

    /// An empty signature field to sign; nil makes a new field named "Signature1" and so on.
    public var fieldName: String?

    /// Page of a new field, from 0.
    public var pageIndex = 0

    /// Where a new field sits (user space). Nil makes it invisible; a field that exists keeps its own rectangle.
    public var rect: PdfRect?

    public var look: SignatureLook?

    /// The /Name entry; the certificate's common name when nil.
    public var name: String?

    public var reason: String?
    public var location: String?
    public var contactInfo: String?

    /// Certifies the file (/DocMDP): the first signature only.
    public var certify = CertificationLevel.none

    public var lock: FieldLock?

    /// Adds an RFC 3161 time stamp to the signature: PAdES B-T.
    public var timestamp: TimestampSettings?

    /// B-B by default. T needs `timestamp`; LT also adds /DSS with the revocation data and LTA a document time stamp
    /// after it, both fetched through the transport of `timestamp`.
    public var level = PadesLevel.b

    public var fonts: FontSource?

    /// Bytes kept for the signature; 0 works it out from the certificates. A signature that does not fit is retried with more room.
    public var reserveBytes = 0

    public init(_ certificate: X509Certificate, _ time: DateTimeOffset) {
        self.certificate = certificate
        self.time = time
    }
}
