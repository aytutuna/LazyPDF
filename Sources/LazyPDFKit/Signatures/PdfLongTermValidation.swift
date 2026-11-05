import Foundation

// Twin of windows/LazyPDF.Core/Signatures/PdfLongTermValidation.cs: adds a /DSS (ETSI EN 319 142-1, PAdES B-LT) to a
// file: the certificates of every signature's chain, and for each certificate an OCSP response or CRL, as an
// incremental update, with a /VRI entry per signature. The responders are reached through the caller's transport; a
// certificate none of them answers for is left without.

public enum PdfLongTermValidation {
    private static let maxChain = 8

    /// The file with the validation data added; the same bytes when it already had it all. Throws
    /// `InvalidOperationException` when the file has no signature.
    public static func add(_ pdf: [UInt8], _ transport: SignatureTransport, _ time: DateTimeOffset, password: String? = nil) throws -> [UInt8] {
        let document = try PdfDocument.open(pdf, password: password)
        try add(document, transport, time)
        return try document.saveIncremental()
    }

    public static func add(_ session: PdfEditSession, _ transport: SignatureTransport, _ time: DateTimeOffset) throws {
        try add(session.document, transport, time)
        try session.commit(L10n.t("Validation data"))
    }

    static func add(_ document: PdfDocument, _ transport: SignatureTransport, _ time: DateTimeOffset) throws {
        let signatures = SignatureScan.find(document.source)
        if signatures.isEmpty { throw InvalidOperationException(SignatureText.notSigned) }
        let dss = try DssWriter(document)
        for found in signatures {
            guard let contents = (found.dictionary["Contents"] as? PdfString)?.bytes else { continue }
            let vouching = Self.subjects(contents)
            var pool = vouching.pool
            if vouching.subjects.isEmpty { continue }
            let entry = DssWriter.Entry()
            for subject in vouching.subjects {
                let chain = buildChain(subject, &pool, transport)
                for certificate in chain { entry.certificates.append(try dss.certificate(certificate)) }
                var i = 0
                while i + 1 < chain.count {
                    try revocation(chain[i], chain[i + 1], transport, dss, entry)
                    i += 1
                }
            }
            dss.signature(Array(contents[0..<vouching.length]), entry, time)
        }
        try dss.save()
    }

    // The certificates that vouch for a signature: its signer, and the authority of an embedded time stamp or a document time stamp.
    private static func subjects(_ contents: [UInt8]) -> (subjects: [X509Certificate], pool: [X509Certificate], length: Int) {
        var subjects: [X509Certificate] = []
        var pool: [X509Certificate] = []
        var length = 0
        if let cms = CmsSignature.parse(contents) {
            length = cms.length
            pool += cms.certificates
            if let signer = cms.findSigner() { subjects.append(signer) }
            if let token = cms.unsignedAttributes[Oids.timestampToken]?.first { addToken(token, &subjects, &pool) }
        } else {
            addToken(contents, &subjects, &pool)
            length = contents.count
            if let (_, consumed) = Rfc3161Token.tryDecode(contents) { length = consumed }
        }
        return (subjects, pool, length)
    }

    private static func addToken(_ encoded: [UInt8], _ subjects: inout [X509Certificate], _ pool: inout [X509Certificate]) {
        guard let (token, _) = Rfc3161Token.tryDecode(encoded) else { return }
        pool += token.cms.certificates
        if let tsa = token.signerCertificate { subjects.append(tsa) }
    }

    // The chain from the certificate up, with issuers fetched from the certificate's own links when the pool lacks them.
    private static func buildChain(_ leaf: X509Certificate, _ pool: inout [X509Certificate], _ transport: SignatureTransport) -> [X509Certificate] {
        var chainCertificates = [leaf]
        for _ in 0..<maxChain {
            chainCertificates = [leaf]
            while let last = chainCertificates.last, !last.isSelfIssued,
                  let issuer = CertificateTrust.issuerOf(last, pool, chainCertificates), chainCertificates.count < 16 {
                chainCertificates.append(issuer)
            }
            guard let last = chainCertificates.last, !last.isSelfIssued else { break }
            var issuer: X509Certificate?
            for url in CertificateLinks.issuerUrls(last) {
                if let bytes = transport.get(url), let loaded = X509Certificate(bytes) {
                    issuer = loaded
                    break
                }
            }
            guard let found = issuer, !pool.contains(where: { $0.thumbprint == found.thumbprint }) else { break }
            pool.append(found)
        }
        return chainCertificates
    }

    private static func revocation(_ certificate: X509Certificate, _ issuer: X509Certificate, _ transport: SignatureTransport, _ dss: DssWriter, _ entry: DssWriter.Entry) throws {
        for url in CertificateLinks.ocspUrls(certificate) {
            if let answer = transport.post(url, "application/ocsp-request", OcspResponse.buildRequest(certificate, issuer)),
               let ocsp = OcspResponse.parse(answer), ocsp.about(certificate, issuer).state != .noData {
                entry.ocsps.append(try dss.ocsp(answer))
                return
            }
        }
        for url in CertificateLinks.crlUrls(certificate) {
            if let bytes = transport.get(url), let crl = Crl.parse(bytes), crl.about(certificate, issuer).state != .noData {
                entry.crls.append(try dss.crl(bytes))
                return
            }
        }
    }
}
