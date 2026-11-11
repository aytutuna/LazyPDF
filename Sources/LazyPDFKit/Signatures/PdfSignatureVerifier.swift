import Foundation
#if canImport(Security)
import Security
#endif

// Twin of windows/LazyPDF.Core/Signatures/PdfSignatureVerifier.cs: checks every signature in a file: the byte range,
// the digest, the CMS signature, the signer's certificate and chain at the time of signing, an embedded time stamp,
// revocation data from the signature and /DSS, and what changed after the signature. Reading never throws on file
// contents except `PdfReadException` from opening the file. Where the platform has no Security framework no
// signature is good: the signature check answers "bad signature" (SignatureCrypto.swift).

public enum PdfSignatureVerifier {
    public static func verify(_ pdf: [UInt8], _ options: VerifyOptions? = nil) throws -> [SignatureReport] {
        let options = options ?? VerifyOptions()
        let document = try open(pdf, options)
        let file = document.source
        let found = SignatureScan.find(file).sorted { $0.offset < $1.offset }
        let checker = SignatureChecker(document, file, PdfRevisions.list(file), options, found)
        var reports = found.enumerated().map { checker.check($0.element, $0.offset) }
        for i in 0..<reports.count {
            // Long term validation archives data in the file; a time stamp over it, later, keeps that data trustworthy.
            if reports[i].level == .lt && reports[(i + 1)...].contains(where: {
                $0.kind == .documentTimestamp && ($0.verdict == .valid || $0.verdict == .validButUntrusted)
            }) {
                reports[i].level = .lta
            }
        }
        return reports
    }

    public static func verify(_ session: PdfEditSession, _ options: VerifyOptions? = nil) throws -> [SignatureReport] {
        try verify(session.current, options)
    }

    private static func open(_ pdf: [UInt8], _ options: VerifyOptions) throws -> PdfDocument {
        #if canImport(Security)
        if let certificate = options.certificate, let sec = SecCertificateCreateWithData(nil, Data(certificate.rawData) as CFData) {
            return try PdfDocument.open(pdf, certificate: PdfCertificate(certificate: sec, privateKey: certificate.privateKey, keyHolder: certificate.keyHolder))
        }
        #endif
        return try PdfDocument.open(pdf, password: options.password)
    }
}

final class SignatureChecker {
    private let document: PdfDocument
    private let file: [UInt8]
    private let revisions: [PdfRevision]
    private let options: VerifyOptions
    private let dss: ValidationData
    private let signatures: Set<Int>
    private var fieldNamesCache: [Int: String]?

    init(_ document: PdfDocument, _ file: [UInt8], _ revisions: [PdfRevision], _ options: VerifyOptions, _ found: [FoundSignature]) {
        self.document = document
        self.file = file
        self.revisions = revisions
        self.options = options
        dss = ValidationData.readDss(document)
        var sound = Set<Int>()
        for f in found {
            if let ranges = SignedRanges.check(file, f, revisions), CmsSignature.parse(ranges.contents) != nil { sound.insert(f.offset) }
        }
        signatures = sound
    }

    func check(_ found: FoundSignature, _ index: Int) -> SignatureReport {
        let dictionary = dictionaryOf(found)
        let subFilter = document.name(dictionary, "SubFilter") ?? ""
        let stamp = document.name(dictionary, "Type") == "DocTimeStamp" || subFilter == "ETSI.RFC3161"
        var report = SignatureReport()
        report.index = index
        report.fieldName = fieldNames()[found.number]
        report.kind = stamp ? .documentTimestamp : .approval
        report.subFilter = subFilter
        report.signerName = stamp ? nil : PdfText.read(document, dictionary["Name"])
        report.reason = PdfText.read(document, dictionary["Reason"])
        report.location = PdfText.read(document, dictionary["Location"])
        report.signingTime = PdfDate.parse(PdfText.read(document, dictionary["M"]))

        guard let ranges = SignedRanges.check(file, found, revisions) else { return fail(report, .broken, .badByteRange) }
        report.revision = ranges.revision.number
        report.coversWholeFile = isBlank(ranges.end, file.count)

        let outcome = stamp ? checkTimestamp(report, ranges) : checkSignature(report, ranges, subFilter)
        return outcome.verdict == .broken || outcome.verdict == .unknown ? outcome : withChanges(outcome, ranges, found)
    }

    private func checkSignature(_ report: SignatureReport, _ ranges: SignedRanges, _ subFilter: String) -> SignatureReport {
        if subFilter != "adbe.pkcs7.detached" && subFilter != "ETSI.CAdES.detached" { return fail(report, .unknown, .unsupportedFormat) }
        guard let cms = CmsSignature.parse(ranges.contents) else { return fail(report, .broken, .badSignature) }
        if ranges.contents[cms.length...].contains(where: { $0 != 0 }) { return fail(report, .broken, .badSignature) }
        guard let signer = cms.findSigner() else { return fail(report, .unknown, .noCertificate) }

        if !cms.signingCertificateMatches(signer) { return fail(report, .broken, .badSignature) }

        var problems: [SignatureProblem] = []
        var digests: [HashAlgorithmName: [UInt8]] = [:]
        let check = CmsVerifier.check(cms, signer) { algorithm in
            if let known = digests[algorithm] { return known }
            let made = ranges.digest(file, algorithm)
            digests[algorithm] = made
            return made
        }
        switch check {
        case .digestMismatch: return fail(report, .broken, .digestMismatch)
        case .badSignature: return fail(report, .broken, .badSignature)
        case .unsupported: return fail(report, .unknown, .unsupportedFormat)
        case .ok: break
        }
        if cms.digestOid == "1.3.14.3.2.26" { problems.append(.weakDigest) }
        if Self.hasWeakKey(signer) { problems.append(.weakKey) }

        let extra = cms.certificates + dss.certificates
        var stamped: DateTimeOffset?
        if let tokens = cms.unsignedAttributes[Oids.timestampToken], let first = tokens.first {
            stamped = checkToken(first, cms.signature, extra, &problems)
        }
        let signingTime = cms.signingTime() ?? report.signingTime
        // The signer's own clock proves nothing; without a trusted time stamp the chain is judged now.
        let time = stamped ?? options.now

        let trust = CertificateTrust.evaluate(signer, extra, time, options)
        if !trust.trusted { problems.append(.untrustedSigner) }
        var claimedOutside = false
        if stamped == nil, let claimed = signingTime { claimedOutside = claimed < signer.notBefore || claimed > signer.notAfter }
        if !trust.timeValid || claimedOutside { problems.append(.certificateNotValid) }

        let evidence = ValidationData()
        evidence.readArchival(cms)
        evidence.certificates += dss.certificates
        evidence.ocsps += dss.ocsps
        evidence.crls += dss.crls
        var checkedAll = trust.chain.count > 1
        var i = 0
        while i + 1 < trust.chain.count {
            let (state, at) = evidence.check(trust.chain[i], trust.chain[i + 1], time)
            if state == .revoked {
                var sinceThen = true
                if let time, let at { sinceThen = at <= time }
                if sinceThen { problems.append(.certificateRevoked) }
            }
            checkedAll = checkedAll && state == .good
            i += 1
        }

        let cades = report.subFilter == "ETSI.CAdES.detached"
        var level = PadesLevel.none
        if cades && cms.attributes[Oids.signingCertificateV2] != nil {
            level = .b
            if stamped != nil && !problems.contains(.timestampInvalid) { level = .t }
            if level == .t && checkedAll { level = .lt }
        }

        var result = report
        result.certificate = signer
        let name = SignJob.certificateName(signer)
        if !name.isEmpty { result.signerName = name }
        result.signingTime = signingTime
        result.timestampTime = stamped
        result.timeUsed = time
        result.level = level
        result.revocationChecked = checkedAll
        var distinct: [SignatureProblem] = []
        for problem in problems where !distinct.contains(problem) { distinct.append(problem) }
        result.problems = distinct
        result.verdict = problems.isEmpty ? .valid : .validButUntrusted
        return result
    }

    private func checkTimestamp(_ report: SignatureReport, _ ranges: SignedRanges) -> SignatureReport {
        guard let (token, length) = Rfc3161Token.tryDecode(ranges.contents) else { return fail(report, .broken, .badSignature) }
        if ranges.contents[length...].contains(where: { $0 != 0 }) { return fail(report, .broken, .badSignature) }
        guard let algorithm = Oids.digestName(token.hashOid) else { return fail(report, .unknown, .unsupportedFormat) }
        let hash = ranges.digest(file, algorithm)
        if token.messageHash != hash { return fail(report, .broken, .digestMismatch) }
        let carried = token.cms.certificates
        guard let tsa = token.verifySignatureForHash(hash, algorithm, dss.certificates + carried) else { return fail(report, .broken, .badSignature) }

        var problems: [SignatureProblem] = []
        let time = token.timestamp
        let trust = CertificateTrust.evaluate(tsa, dss.certificates + carried, time, options, timestamp: true)
        if !trust.trusted { problems.append(.untrustedSigner) }
        if !trust.timeValid { problems.append(.certificateNotValid) }
        var result = report
        result.certificate = tsa
        result.signingTime = time
        result.timestampTime = time
        result.timeUsed = time
        result.problems = problems
        result.verdict = problems.isEmpty ? .valid : .validButUntrusted
        return result
    }

    private func checkToken(_ encoded: [UInt8], _ signature: [UInt8], _ extra: [X509Certificate], _ problems: inout [SignatureProblem]) -> DateTimeOffset? {
        guard let (token, _) = Rfc3161Token.tryDecode(encoded), let algorithm = Oids.digestName(token.hashOid) else {
            problems.append(.timestampInvalid)
            return nil
        }
        let hash = CmsBuilder.hashData(algorithm, signature)
        guard let tsa = token.verifySignatureForHash(hash, algorithm, extra) else {
            problems.append(.timestampInvalid)
            return nil
        }
        let time = token.timestamp
        let trust = CertificateTrust.evaluate(tsa, extra + token.cms.certificates, time, options, timestamp: true)
        if !trust.trusted || !trust.timeValid {
            problems.append(.timestampInvalid)
            return nil
        }
        return time
    }

    // The signature is intact; what is left is whether the file stayed as signed.
    private func withChanges(_ report: SignatureReport, _ ranges: SignedRanges, _ found: FoundSignature) -> SignatureReport {
        var level = 0
        var changes = SignatureChangeReport.none
        var kind = report.kind
        if !isBlank(ranges.end, file.count) {
            let signed: PdfDocument
            do {
                signed = try PdfDocument.open(Array(file[0..<ranges.end]), password: options.password)
            } catch {
                return fail(report, .unknown, .damagedStructure)
            }
            if signed.xrefRebuilt { return fail(report, .unknown, .damagedStructure) }
            let (signedLevel, certification) = Self.level(signed, found.number)
            level = signedLevel
            if certification && kind == .approval { kind = .certification }
            let later = revisions.filter { $0.end > ranges.revision.end }.count
            changes = ChangeDetector.compare(signed, document, level, signatures)
            changes.revisionsAfter = later
        } else if kind == .approval {
            let (current, certification) = Self.level(document, found.number)
            level = current
            if certification { kind = .certification }
        }

        var problems = report.problems
        var verdict = report.verdict
        if !changes.allAllowed {
            problems.append(.changedAfterSigning)
            verdict = .changedAfterSigning
        }
        var result = report
        result.kind = kind
        result.certification = CertificationLevel(rawValue: level) ?? .none
        result.changes = changes
        result.problems = problems
        result.verdict = verdict
        return result
    }

    // The access permission in force for a signature: 0 for a file that is not certified.
    static func level(_ document: PdfDocument, _ signatureNumber: Int) -> (level: Int, certification: Bool) {
        guard let perms = document.dict(document.catalog, "Perms"), let reference = perms["DocMDP"] as? PdfReference else { return (0, false) }
        guard let signature = document.resolve(reference) as? PdfDictionary else { return (0, false) }
        var level = 2
        if let references = document.array(signature, "Reference") {
            for item in references.items {
                if let r = document.resolve(item) as? PdfDictionary, document.name(r, "TransformMethod") == "DocMDP",
                   let parameters = document.dict(r, "TransformParams"), let p = document.integer(parameters, "P") {
                    level = min(max(p, 1), 3)
                }
            }
        }
        return (level, reference.number == signatureNumber)
    }

    private static let smallCurves: Set<String> = [
        "1.2.840.10045.3.1.1",
        "1.3.132.0.1", "1.3.132.0.2", "1.3.132.0.3", "1.3.132.0.4", "1.3.132.0.5", "1.3.132.0.6", "1.3.132.0.7",
        "1.3.132.0.8", "1.3.132.0.9", "1.3.132.0.15", "1.3.132.0.16", "1.3.132.0.24", "1.3.132.0.25", "1.3.132.0.28",
        "1.3.132.0.29", "1.3.36.3.3.2.8.1.1.1", "1.3.36.3.3.2.8.1.1.3", "1.3.36.3.3.2.8.1.1.5",
    ]

    static func hasWeakKey(_ certificate: X509Certificate) -> Bool {
        switch certificate.publicKeyAlgorithm {
        case Oids.rsaEncryption, Oids.rsaPss:
            var key = AsnReader(certificate.encodedKeyValue)
            guard var numbers = try? key.readSequence(), let modulus = try? numbers.readInteger(),
                  let top = modulus.magnitude.first else { return false }
            return (modulus.magnitude.count - 1) * 8 + top.bitWidth - top.leadingZeroBitCount < 2048
        case Oids.ecPublicKey:
            var parameters = AsnReader(certificate.publicKeyParameters)
            guard let curve = try? parameters.readObjectIdentifier() else { return false }
            return smallCurves.contains(curve)
        default:
            return false
        }
    }
    private func fail(_ report: SignatureReport, _ verdict: SignatureVerdict, _ problem: SignatureProblem) -> SignatureReport {
        var result = report
        result.verdict = verdict
        result.problems = [problem]
        return result
    }

    // At most one end-of-line follows the last %%EOF; any more is a tail for the change rules to read, whatever it holds.
    private func isBlank(_ from: Int, _ to: Int) -> Bool {
        let tail = Array(file[from..<to])
        return tail.isEmpty || tail == [10] || tail == [13] || tail == [13, 10]
    }

    // The final file's own copy of the signature object when it is the one in the bytes: decrypted, with references usable.
    private func dictionaryOf(_ found: FoundSignature) -> PdfDictionary {
        if let entry = document.entries[found.number], entry.kind == .inUse, entry.offset == found.offset,
           let current = document.get(found.number) as? PdfDictionary {
            return current
        }
        return found.dictionary
    }

    private func fieldNames() -> [Int: String] {
        if let known = fieldNamesCache { return known }
        var names: [Int: String] = [:]
        for field in PdfForm.read(document).fields where field.kind == .signature {
            if let r = field.dictionary["V"] as? PdfReference, names[r.number] == nil { names[r.number] = field.name }
        }
        fieldNamesCache = names
        return names
    }
}
