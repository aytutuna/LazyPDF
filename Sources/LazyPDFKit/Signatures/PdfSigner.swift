import Foundation
#if canImport(Security)
import Security
#endif

// Twin of windows/LazyPDF.Core/Signatures/PdfSigner.cs: applies signatures (ISO 32000-1 12.8, ETSI EN 319 142 PAdES)
// and document time stamps. A signature is always an incremental update: the bytes of the file stay as they were,
// and the signature covers all of them. Throws `InvalidOperationException` with a `SignatureText` message for what the
// user can fix (a taken field, a missing key, a seed value that cannot be met) and `ArgumentException` for a bad page.
//
// The chain to embed is the request's own, else the one the system builds from its store (SecTrust, no downloads, no
// revocation check); where it builds none, nothing is embedded.

public enum PdfSigner {
    private static let baseReserve = 4096
    private static let timestampReserve = 14000

    /// The file with the signature added; the same bytes plus an update.
    public static func sign(_ pdf: [UInt8], _ request: PdfSignRequest, password: String? = nil) throws -> [UInt8] {
        let job = SignJob(request)
        var file = try signOnce(PdfDocument.open(pdf, password: password), job)
        if job.level >= .lt {
            guard let stamp = request.timestamp else { throw InvalidOperationException(SignatureText.noTimestampServer) }
            let document = try PdfDocument.open(file, password: password)
            try PdfLongTermValidation.add(document, stamp.transport, request.time)
            file = try document.saveIncremental()
        }
        if job.level == .lta {
            guard let stamp = request.timestamp else { throw InvalidOperationException(SignatureText.noTimestampServer) }
            file = try documentTimestamp(PdfDocument.open(file, password: password), stamp, request.time)
        }
        return file
    }

    /// Signs the session's file: one step for the signature, one more for each of the validation data and the time stamp that the level adds.
    public static func sign(_ session: PdfEditSession, _ request: PdfSignRequest) throws {
        let job = SignJob(request)
        try session.commitBytes(L10n.t("Sign"), signOnce(session.document, job))
        if job.level >= .lt {
            guard let stamp = request.timestamp else { throw InvalidOperationException(SignatureText.noTimestampServer) }
            try PdfLongTermValidation.add(session.document, stamp.transport, request.time)
            try session.commit(L10n.t("Validation data"))
        }
        if job.level == .lta {
            guard let stamp = request.timestamp else { throw InvalidOperationException(SignatureText.noTimestampServer) }
            try session.commitBytes(L10n.t("Time stamp"), documentTimestamp(session.document, stamp, request.time))
        }
    }

    /// Adds a document time stamp (ETSI.RFC3161) over the whole file, which keeps earlier signatures and validation data verifiable once their certificates expire.
    public static func addDocumentTimestamp(_ pdf: [UInt8], _ settings: TimestampSettings, _ time: DateTimeOffset, password: String? = nil) throws -> [UInt8] {
        try documentTimestamp(PdfDocument.open(pdf, password: password), settings, time)
    }

    public static func addDocumentTimestamp(_ session: PdfEditSession, _ settings: TimestampSettings, _ time: DateTimeOffset) throws {
        try session.commitBytes(L10n.t("Time stamp"), documentTimestamp(session.document, settings, time))
    }

    private static func signOnce(_ document: PdfDocument, _ job: SignJob) throws -> [UInt8] {
        let request = job.request
        if request.signer == nil && !hasPrivateKey(request.certificate) { throw InvalidOperationException(SignatureText.noPrivateKey) }
        _ = try Oids.digest(request.digest)

        let target = try SignatureField.resolve(document, job)
        if let refusal = SignatureField.refusal(document, target) { throw InvalidOperationException(refusal) }
        if job.certify != .none && !SignatureScan.find(document.source).isEmpty { throw InvalidOperationException(SignatureText.notCertifiable) }
        if job.level >= .t && request.timestamp == nil { throw InvalidOperationException(SignatureText.noTimestampServer) }
        let url = job.timestampUrl
        if request.timestamp != nil && url == nil { throw InvalidOperationException(SignatureText.noTimestampServer) }
        _ = try Oids.digest(job.digest)

        let visible = !target.rect.isEmpty
        let look = request.look ?? SignatureLook()
        let text = visible ? SignatureAppearance.text(job, look) : ""
        let font = try visible ? SignatureAppearance.addFont(document, job, look, text) : nil
        let appearance = try visible ? SignatureAppearance.draw(document, target.rect, target.page.rotate, look, text, font) : nil

        let chain = embeddedChain(request)
        let reserve = request.reserveBytes > 0
            ? request.reserveBytes
            : baseReserve + request.certificate.rawData.count + chain.reduce(0) { $0 + $1.rawData.count } + (request.timestamp == nil ? 0 : timestampReserve)
        let contents = PdfString(bytes: [UInt8](repeating: 0, count: reserve), isHex: true)
        let subFilter = job.format == .cadesDetached ? "ETSI.CAdES.detached" : "adbe.pkcs7.detached"
        let signature = try document.add(SignatureField.dictionary(document, job, contents, subFilter))
        if target.isNew, let fieldLock = job.lock { SignatureField.writeLock(target.field, fieldLock) }
        try SignatureField.attach(document, target, signature, appearance)
        if job.certify != .none { SignatureField.certify(document, signature) }

        let settings = CmsSettings(certificate: request.certificate, chain: chain, digest: job.digest, cades: job.format == .cadesDetached,
                                   time: request.time, external: request.signer)
        var stamp: (([UInt8]) throws -> [UInt8]?)?
        if let s = request.timestamp, let url { stamp = { value in try TimestampClient.request(s, url, value) } }
        return try SignedUpdate.build(document, contents, job.digest) { digest in try CmsBuilder.build(digest, settings, stamp) }
    }

    private static func embeddedChain(_ request: PdfSignRequest) -> [X509Certificate] {
        if !request.chain.isEmpty { return request.chain }
        #if canImport(Security)
        guard let leaf = SecCertificateCreateWithData(nil, Data(request.certificate.rawData) as CFData) else { return [] }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else { return [] }
        SecTrustSetNetworkFetchAllowed(trust, false)
        // The result does not matter: the evaluation builds the chain, and a chain that ends short is embedded as far as it goes.
        _ = SecTrustEvaluateWithError(trust, nil)
        let found = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return found.dropFirst().compactMap { X509Certificate([UInt8](SecCertificateCopyData($0) as Data)) }.filter { !$0.isSelfIssued }
        #else
        return []
        #endif
    }

    private static func hasPrivateKey(_ certificate: X509Certificate) -> Bool {
        #if canImport(Security)
        return certificate.privateKey != nil
        #else
        return false
        #endif
    }

    private static func documentTimestamp(_ document: PdfDocument, _ settings: TimestampSettings, _ time: DateTimeOffset) throws -> [UInt8] {
        guard let url = settings.url else { throw InvalidOperationException(SignatureText.noTimestampServer) }
        let form = PdfForm.read(document)
        let name = SignatureField.unique(form, "Timestamp")
        let field = PdfDictionary()
        let pages = document.pages
        guard pages.count > 0 else { throw ArgumentException(SignatureText.noPage) }
        let target = SignatureField.Target(field: field, fieldReference: nil, widget: field, rect: PdfRect(0, 0, 0, 0), page: pages[0],
                                           isNew: true, placed: false, name: name)

        let contents = PdfString(bytes: [UInt8](repeating: 0, count: timestampReserve), isHex: true)
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("DocTimeStamp")
        dictionary["Filter"] = PdfName("Adobe.PPKLite")
        dictionary["SubFilter"] = PdfName("ETSI.RFC3161")
        dictionary["ByteRange"] = SignedUpdate.byteRangePlaceholder()
        dictionary["Contents"] = contents
        let signature = try document.add(dictionary)
        try SignatureField.attach(document, target, signature, nil)
        return try SignedUpdate.build(document, contents, settings.digest) { digest in try TimestampClient.request(settings, url, digest, hashed: true) }
    }
}
