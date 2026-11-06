import Foundation

// Twin of windows/LazyPDF.Core/Signatures/SeedValues.cs: the request after a field's seed values (ISO 32000-1
// 12.7.4.5) have had their say. Only the seed values that decide how a signature is made are obeyed; the rest (legal
// attestation, the URL and policy tests of /Cert) are refused outright when the field marks them required.

final class SignJob {
    let request: PdfSignRequest
    var format: SignatureFormat
    var digest: HashAlgorithmName
    var reason: String?
    var certify: CertificationLevel
    var lock: FieldLock?
    var level: PadesLevel
    var timestampUrl: String?
    let name: String

    init(_ request: PdfSignRequest) {
        self.request = request
        format = request.format
        digest = request.digest
        reason = request.reason
        certify = request.certify
        lock = request.lock
        level = request.timestamp != nil && request.level == .b ? .t : request.level
        timestampUrl = request.timestamp?.url
        name = request.name ?? Self.certificateName(request.certificate)
    }

    static func certificateName(_ certificate: X509Certificate) -> String {
        let name = certificate.simpleName
        return name.isEmpty ? certificate.subject : name
    }
}

enum SeedValues {
    private static let supportedFilters = ["ETSI.CAdES.detached", "adbe.pkcs7.detached"]

    static func apply(_ document: PdfDocument, _ field: PdfDictionary, _ job: SignJob) throws {
        guard let sv = document.dict(field, "SV") else { return }
        let flags = document.integer(sv, "Ff") ?? 0
        func required(_ bit: Int) -> Bool { flags & (1 << (bit - 1)) != 0 }

        if required(1), let filter = document.name(sv, "Filter"), filter != "Adobe.PPKLite" { throw InvalidOperationException(SignatureText.seedUnsupported) }

        if let subFilters = document.array(sv, "SubFilter") {
            let names = subFilters.items.compactMap { (document.resolve($0) as? PdfName)?.value }
            let current = job.format == .cadesDetached ? "ETSI.CAdES.detached" : "adbe.pkcs7.detached"
            if required(2) && !names.contains(current) {
                guard let chosen = names.first(where: { supportedFilters.contains($0) }) else { throw InvalidOperationException(SignatureText.seedFormat) }
                job.format = chosen == "ETSI.CAdES.detached" ? .cadesDetached : .pkcs7Detached
            }
        }

        if let reasons = document.array(sv, "Reasons") {
            let list = reasons.items.compactMap { PdfText.read(document, $0) }
            if required(4) && !list.isEmpty {
                if let reason = job.reason {
                    if !list.contains(where: { sameText($0, reason) }) { throw InvalidOperationException(SignatureText.seedReason) }
                } else {
                    job.reason = list[0]
                }
            }
        }

        if required(5), let attestation = document.array(sv, "LegalAttestation"), !attestation.items.isEmpty {
            throw InvalidOperationException(SignatureText.seedUnsupported)
        }

        if required(6) && document.bool(sv, "AddRevInfo") == true && job.level < .lt {
            if job.request.timestamp == nil { throw InvalidOperationException(SignatureText.noTimestampServer) }
            job.level = .lt
        }

        if required(7), let digests = document.array(sv, "DigestMethod") {
            let names = digests.items.compactMap { (document.resolve($0) as? PdfName)?.value }
            let current = job.digest.rawValue
            if !names.contains(current) {
                guard let chosen = names.first(where: { $0 == "SHA256" || $0 == "SHA384" || $0 == "SHA512" }),
                      let algorithm = HashAlgorithmName(rawValue: chosen) else { throw InvalidOperationException(SignatureText.seedDigest) }
                job.digest = algorithm
            }
        }

        if let mdp = document.dict(sv, "MDP"), let p = document.integer(mdp, "P") {
            if p == 0 && job.certify != .none { throw InvalidOperationException(SignatureText.seedCertification) }
            if p >= 1 && p <= 3 {
                if job.certify != .none && job.certify.rawValue != p { throw InvalidOperationException(SignatureText.seedCertification) }
                job.certify = CertificationLevel(rawValue: p) ?? .none
            }
        }

        if let stamp = document.dict(sv, "TimeStamp") {
            let isRequired = document.integer(stamp, "Ff") == 1
            if isRequired && job.request.timestamp == nil { throw InvalidOperationException(SignatureText.noTimestampServer) }
            if job.request.timestamp != nil && job.timestampUrl == nil { job.timestampUrl = PdfText.read(document, stamp["URL"]) }
        }

        if let cert = document.dict(sv, "Cert") { try checkCertificate(document, cert, job) }
    }

    private static func checkCertificate(_ document: PdfDocument, _ cert: PdfDictionary, _ job: SignJob) throws {
        let flags = document.integer(cert, "Ff") ?? 0
        func required(_ bit: Int) -> Bool { flags & (1 << (bit - 1)) != 0 }
        let certificate = job.request.certificate

        if required(1) && !certificates(document, cert["Subject"]).contains(where: { $0.rawData == certificate.rawData }) {
            throw InvalidOperationException(SignatureText.seedCertificate)
        }
        if required(2) {
            let issuers = certificates(document, cert["Issuer"]).map { $0.subjectName }
            let chain = job.request.chain + [certificate]
            if !chain.contains(where: { c in issuers.contains(c.issuerName) }) { throw InvalidOperationException(SignatureText.seedCertificate) }
        }
        if required(3) || required(6) { throw InvalidOperationException(SignatureText.seedUnsupported) }
        if required(4), let dns = document.array(cert, "SubjectDN"),
           !dns.items.compactMap({ document.resolve($0) as? PdfDictionary }).contains(where: { matchesName(document, $0, certificate) }) {
            throw InvalidOperationException(SignatureText.seedCertificate)
        }
        if required(5), let usages = document.array(cert, "KeyUsage"),
           !usages.items.compactMap({ PdfText.read(document, $0) }).contains(where: { matchesUsage($0, certificate) }) {
            throw InvalidOperationException(SignatureText.seedCertificate)
        }
    }

    private static func certificates(_ document: PdfDocument, _ array: PdfObject?) -> [X509Certificate] {
        guard let items = document.resolve(array) as? PdfArray else { return [] }
        var found: [X509Certificate] = []
        for item in items.items {
            // A seed entry that is not a certificate matches nothing.
            if let string = document.resolve(item) as? PdfString, let loaded = X509Certificate(string.bytes) { found.append(loaded) }
        }
        return found
    }

    private static func matchesName(_ document: PdfDocument, _ wanted: PdfDictionary, _ certificate: X509Certificate) -> Bool {
        let present = X509Certificate.attributes(certificate.subjectName) ?? []
        for (key, value) in wanted.entries {
            let oid: String
            switch key {
            case "C": oid = "2.5.4.6"
            case "O": oid = "2.5.4.10"
            case "OU": oid = "2.5.4.11"
            case "CN": oid = "2.5.4.3"
            case "L": oid = "2.5.4.7"
            case "ST": oid = "2.5.4.8"
            case "E": oid = "1.2.840.113549.1.9.1"
            default: oid = key
            }
            guard let text = PdfText.read(document, value), present.contains(where: { $0.oid == oid && sameText($0.value, text) }) else { return false }
        }
        return true
    }

    // Nine characters, one per key usage bit from digitalSignature: 1 must be set, 0 must be clear, X does not matter.
    private static func matchesUsage(_ pattern: String, _ certificate: X509Certificate) -> Bool {
        let usage = ((try? certificate.keyUsage()) ?? nil) ?? []
        let bits: [KeyUsage] = [.digitalSignature, .nonRepudiation, .keyEncipherment, .dataEncipherment, .keyAgreement, .keyCertSign, .crlSign,
                                .encipherOnly, .decipherOnly]
        for (i, c) in pattern.utf16.prefix(bits.count).enumerated() {
            let set = usage.contains(bits[i])
            if (c == 0x31 && !set) || (c == 0x30 && set) { return false }
        }
        return true
    }
}

/// Text compared as the C# compares it with `==`: unit by unit, not by canonical equivalence.
func sameText(_ a: String, _ b: String) -> Bool {
    a.utf16.elementsEqual(b.utf16)
}
