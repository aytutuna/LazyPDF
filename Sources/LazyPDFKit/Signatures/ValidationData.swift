import Foundation
#if canImport(Security)
import Security
#endif

// Twin of windows/LazyPDF.Core/Signatures/ValidationData.cs: certificates and revocation data a file carries for its
// signatures: the /DSS, and what a signature archived in itself; and the chain of a certificate and whether it can be
// trusted at a given time. The C# gets the chain from X509Chain; here it is built by hand from the certificates
// given, the anchors the caller trusts and, for the system store, Security.framework (SecTrust).

final class ValidationData {
    private static let maxStreams = 4096

    var certificates: [X509Certificate] = []
    var ocsps: [OcspResponse] = []
    var crls: [Crl] = []

    static func readDss(_ document: PdfDocument) -> ValidationData {
        let data = ValidationData()
        guard let dss = document.dict(document.catalog, "DSS") else { return data }
        for bytes in streams(document, dss, "Certs") {
            if let certificate = X509Certificate(bytes) { data.certificates.append(certificate) }
        }
        for bytes in streams(document, dss, "OCSPs") {
            if let ocsp = OcspResponse.parse(bytes) { data.ocsps.append(ocsp) }
        }
        for bytes in streams(document, dss, "CRLs") {
            if let crl = Crl.parse(bytes) { data.crls.append(crl) }
        }
        return data
    }

    private static func streams(_ document: PdfDocument, _ dss: PdfDictionary, _ key: String) -> [[UInt8]] {
        guard let array = document.array(dss, key) else { return [] }
        var found: [[UInt8]] = []
        for item in array.items.prefix(maxStreams) {
            guard let stream = document.resolve(item) as? PdfStream else { continue }
            if let bytes = try? document.data(stream) { found.append(bytes) }
        }
        return found
    }

    /// adbe-revocationInfoArchival: CRLs and OCSP responses the signer put in the signature itself.
    func readArchival(_ cms: CmsSignature) {
        guard let values = cms.attributes[Oids.revocationArchival] else { return }
        for value in values {
            do {
                var outer = AsnReader(value)
                var info = try outer.readSequence()
                while info.hasData {
                    let tag = try info.peekTag()
                    var holder = try info.readSequence(tag)
                    var list = try holder.readSequence()
                    while list.hasData {
                        let der = try list.readEncodedValue()
                        if tag.value == 0, let crl = Crl.parse(der) {
                            crls.append(crl)
                        } else if tag.value == 1, let ocsp = OcspResponse.parse(der) {
                            ocsps.append(ocsp)
                        }
                    }
                }
            } catch {
                // Archived data that does not read adds nothing.
            }
        }
    }

    /// What the data says of `certificate`; a revocation is reported with its time. "Good" counts only when the data holds for `time`, when there is one.
    func check(_ certificate: X509Certificate, _ issuer: X509Certificate, _ time: DateTimeOffset? = nil) -> (state: RevocationState, at: DateTimeOffset?) {
        var state = RevocationState.noData
        for ocsp in ocsps {
            let (s, revokedAt, _) = ocsp.about(certificate, issuer, time)
            if s == .revoked { return (s, revokedAt) }
            if s == .good { state = s }
        }
        for crl in crls {
            let (s, revokedAt) = crl.about(certificate, issuer, time)
            if s == .revoked { return (s, revokedAt) }
            if s == .good && state == .noData { state = s }
        }
        return (state, nil)
    }
}

/// A certificate chain built for a signature, and whether it can be trusted at a given time.
struct TrustResult {
    var trusted: Bool
    var timeValid: Bool
    var chain: [X509Certificate]
}

enum CertificateTrust {
    private struct Flags: OptionSet {
        let rawValue: Int
        static let notTimeValid = Flags(rawValue: 1)
        static let partialChain = Flags(rawValue: 2)
        static let untrustedRoot = Flags(rawValue: 4)
        static let invalidBasicConstraints = Flags(rawValue: 8)
        static let notValidForUsage = Flags(rawValue: 16)
        static let unsupportedExtension = Flags(rawValue: 32)
        static let notSignatureValid = Flags(rawValue: 64)
    }

    // What this chain builder reads or can leave unread without harm. A critical extension outside the list, or any
    // name constraints, policy constraints, policy mappings or inhibitAnyPolicy extension, would restrict the chain in
    // a way that is not enforced here, so the chain is not trusted (.NET reports HasNotSupportedCriticalExtension, a
    // name constraint or InvalidPolicyConstraints for them).
    private static let understood: Set<String> = [
        "2.5.29.14", "2.5.29.15", "2.5.29.17", "2.5.29.18", "2.5.29.19", "2.5.29.31", "2.5.29.32", "2.5.29.35",
        "2.5.29.37", "2.5.29.46", "1.3.6.1.5.5.7.1.1", "1.3.6.1.5.5.7.1.11",
    ]
    private static let restricting: Set<String> = ["2.5.29.30", "2.5.29.33", "2.5.29.36", "2.5.29.54"]

    private static let maxChain = 16
    private static let timeStamping = "1.3.6.1.5.5.7.3.8"
    private static let signingPurposes = [
        "1.3.6.1.5.5.7.3.4", // email protection, which PDF signers have long carried
        "1.2.840.113583.1.1.5", // Adobe PDF signing
        "1.3.6.1.4.1.311.10.3.12", // Microsoft document signing
        "2.5.29.37.0", // any purpose
    ]

    /// The chain of `certificate`, trusted only when it is also meant for the job: signing documents, or for a time stamp authority `timestamp`.
    static func evaluate(_ certificate: X509Certificate, _ extra: [X509Certificate], _ time: DateTimeOffset?, _ options: VerifyOptions, timestamp: Bool = false) -> TrustResult {
        var result = build(certificate, extra, time, options.trustAnchors, system: false)
        if !result.trusted && options.useSystemStore {
            let viaSystem = build(certificate, extra + options.trustAnchors, time, [], system: true)
            if viaSystem.trusted { result = viaSystem }
        }
        if !suits(certificate, timestamp) { result.trusted = false }
        return result
    }

    // RFC 5280 4.2.1.3 and 4.2.1.12; RFC 3161 2.3 asks a time stamp authority for the one purpose.
    // The extensions decode when read, and a certificate in a file may carry one that does not: it suits nothing.
    private static func suits(_ certificate: X509Certificate, _ timestamp: Bool) -> Bool {
        do {
            if let usage = try certificate.keyUsage(), usage.intersection([.digitalSignature, .nonRepudiation]).isEmpty { return false }
            guard let purposes = try certificate.enhancedKeyUsages() else { return !timestamp }
            return timestamp ? purposes.contains(timeStamping) : purposes.contains { signingPurposes.contains($0) }
        } catch {
            return false
        }
    }

    private static func build(_ certificate: X509Certificate, _ extra: [X509Certificate], _ time: DateTimeOffset?, _ anchors: [X509Certificate], system: Bool) -> TrustResult {
        let at = time ?? currentTime()
        if system {
            #if canImport(Security)
            return buildWithSystem(certificate, extra, at)
            #else
            return TrustResult(trusted: false, timeValid: true, chain: [certificate])
            #endif
        }
        let (elements, flags) = chain(certificate, extra, anchors, at)
        let harmless: Flags = [.notTimeValid]
        return TrustResult(trusted: flags.subtracting(harmless).isEmpty, timeValid: !flags.contains(.notTimeValid), chain: elements)
    }

    /// The chain from `leaf` up to an anchor or as far as the certificates lead, and what is wrong with it.
    private static func chain(_ leaf: X509Certificate, _ extra: [X509Certificate], _ anchors: [X509Certificate], _ time: DateTimeOffset) -> ([X509Certificate], Flags) {
        var (elements, flags) = walk(leaf, extra, anchors, time)
        if elements.contains(where: { !supportsExtensions($0) }) { flags.insert(.unsupportedExtension) }
        return (elements, flags)
    }

    private static func supportsExtensions(_ certificate: X509Certificate) -> Bool {
        certificate.extensions.allSatisfy { ext in
            !restricting.contains(ext.oid) && (!ext.critical || understood.contains(ext.oid)) && (ext.oid != "2.5.29.32" || policiesDecode(ext.value))
        }
    }

    // certificatePolicies is SEQUENCE OF PolicyInformation, each an identifier and perhaps qualifiers. .NET refuses a
    // chain with one that does not decode, whether it is critical or not.
    private static func policiesDecode(_ value: [UInt8]) -> Bool {
        do {
            var outer = AsnReader(value)
            var list = try outer.readSequence()
            while list.hasData {
                var policy = try list.readSequence()
                _ = try policy.readObjectIdentifier()
                if policy.hasData { _ = try policy.readSequence() }
                if policy.hasData { return false }
            }
            return !outer.hasData
        } catch {
            return false
        }
    }

    private static func walk(_ leaf: X509Certificate, _ extra: [X509Certificate], _ anchors: [X509Certificate], _ time: DateTimeOffset) -> ([X509Certificate], Flags) {
        var elements = [leaf]
        var flags: Flags = []
        var current = leaf
        var below = 0
        for _ in 0..<maxChain {
            if time < current.notBefore || time > current.notAfter { flags.insert(.notTimeValid) }
            // Only a root ends a chain as trusted; an anchor that was issued by another certificate leaves it partial.
            if anchors.contains(where: { $0.sameBytes(current) }) {
                if !current.isSelfIssued { flags.insert(.partialChain) } else if !signs(current, current) { flags.insert(.notSignatureValid) }
                return (elements, flags)
            }
            if current.isSelfIssued {
                flags.insert(.untrustedRoot)
                return (elements, flags)
            }
            guard let issuer = issuerOf(current, anchors + extra, elements) else {
                flags.insert(.partialChain)
                return (elements, flags)
            }
            if let reason = unfit(issuer, below) { flags.insert(reason) }
            elements.append(issuer)
            below += 1
            current = issuer
        }
        flags.insert(.partialChain)
        return (elements, flags)
    }

    // An issuer holds the name, signs the certificate and is not already in the chain.
    static func issuerOf(_ certificate: X509Certificate, _ pool: [X509Certificate], _ chain: [X509Certificate]) -> X509Certificate? {
        pool.first { candidate in
            candidate.subjectName == certificate.issuerName && !chain.contains { $0.sameBytes(candidate) } && signs(candidate, certificate)
        }
    }

    /// Whether `issuer` made the signature on `certificate`.
    static func signs(_ issuer: X509Certificate, _ certificate: X509Certificate) -> Bool {
        let algorithm = Oids.digestName(OcspResponse.digestOf(certificate.signatureAlgorithm)) ?? .sha256
        return CmsVerifier.verifyRaw(issuer, certificate.signatureAlgorithm, certificate.signatureValue, certificate.tbsCertificate, algorithm)
    }

    // A certificate that issues others is a CA allowed to sign certificates, and has room for the ones below it.
    private static func unfit(_ issuer: X509Certificate, _ below: Int) -> Flags? {
        do {
            guard let constraints = try issuer.basicConstraints(), constraints.certificateAuthority else { return .invalidBasicConstraints }
            if let length = constraints.pathLength, below > length && !issuer.isSelfIssued { return .invalidBasicConstraints }
            if let usage = try issuer.keyUsage(), !usage.contains(.keyCertSign) { return .notValidForUsage }
            return nil
        } catch {
            return .invalidBasicConstraints
        }
    }

    /// `certificate` was issued by `issuer` and both held at `time`: the check for a responder's certificate, with the issuer as the only anchor.
    static func issuedBy(_ certificate: X509Certificate, _ issuer: X509Certificate, _ time: DateTimeOffset) -> Bool {
        let (elements, flags) = chain(certificate, [], [issuer], time)
        return elements.count > 1 && elements[1].sameBytes(issuer) && flags.subtracting([.partialChain]).isEmpty
    }

    #if canImport(Security)
    private static func buildWithSystem(_ certificate: X509Certificate, _ extra: [X509Certificate], _ time: DateTimeOffset) -> TrustResult {
        func secCertificate(_ c: X509Certificate) -> SecCertificate? { SecCertificateCreateWithData(nil, Data(c.rawData) as CFData) }
        guard let leaf = secCertificate(certificate) else { return TrustResult(trusted: false, timeValid: true, chain: [certificate]) }
        let certificates = [leaf] + extra.compactMap { secCertificate($0) }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else {
            return TrustResult(trusted: false, timeValid: true, chain: [certificate])
        }
        // Issuers named in a certificate of the file are not fetched: the C# disables downloads too.
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, Date(timeIntervalSince1970: Double(time.unixSeconds)) as CFDate)
        let trusted = SecTrustEvaluateWithError(trust, nil)
        var elements: [X509Certificate] = []
        for c in (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? [] {
            if let parsed = X509Certificate([UInt8](SecCertificateCopyData(c) as Data)) { elements.append(parsed) }
        }
        if elements.isEmpty { elements = [certificate] }
        let timeValid = !elements.contains { time < $0.notBefore || time > $0.notAfter }
        return TrustResult(trusted: trusted, timeValid: timeValid, chain: elements)
    }
    #endif
}
