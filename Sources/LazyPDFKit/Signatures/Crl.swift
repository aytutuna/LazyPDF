import Foundation

// Twin of windows/LazyPDF.Core/Signatures/Crl.cs: a certificate revocation list (RFC 5280) read far enough to ask
// whether a serial number is on it, and the places a certificate says to ask.

final class Crl {
    private static let issuingDistributionPoint = "2.5.29.28"
    private static let deltaIndicator = "2.5.29.27"

    private var issuer: [UInt8] = []
    private var tbs: [UInt8] = []
    private var signatureOid = ""
    private var signature: [UInt8] = []
    private var revoked: [AsnInteger: DateTimeOffset] = [:]
    private var scope: Scope?
    private var delta = false

    // The issuingDistributionPoint extension (RFC 5280 5.2.5): the part of the issuer's certificates the list speaks for.
    private struct Scope {
        var points: [String]
        var onlyUser: Bool
        var onlyCa: Bool
        var other: Bool
    }

    private(set) var thisUpdate = DateTimeOffset(1, 1, 1, 0, 0, 0)
    private(set) var nextUpdate: DateTimeOffset?
    private(set) var raw: [UInt8] = []

    static func parse(_ der: [UInt8]) -> Crl? {
        do {
            var outer = AsnReader(der)
            var list = try outer.readSequence()
            let crl = Crl()
            crl.raw = der
            crl.tbs = try list.peekEncodedValue()
            var tbs = try list.readSequence()
            var algorithm = try list.readSequence()
            crl.signatureOid = try algorithm.readObjectIdentifier()
            crl.signature = try list.readBitString()
            if try tbs.peekTag().value == AsnUniversal.integer { _ = try tbs.readInteger() }
            _ = try tbs.readSequence()
            crl.issuer = try tbs.readEncodedValue()
            crl.thisUpdate = try readTime(&tbs)
            if tbs.hasData, try isTime(tbs.peekTag().value) { crl.nextUpdate = try readTime(&tbs) }
            if tbs.hasData, try tbs.peekTag().value == AsnUniversal.sequence {
                var entries = try tbs.readSequence()
                while entries.hasData {
                    var entry = try entries.readSequence()
                    let serial = try entry.readInteger()
                    let time = try readTime(&entry)
                    if crl.revoked[serial] == nil { crl.revoked[serial] = time }
                }
            }
            if tbs.hasData, try tbs.peekTag().hasSameClassAndValue(.context(0, constructed: true)) {
                var holder = try tbs.readSequence(.context(0, constructed: true))
                var extensions = try holder.readSequence()
                while extensions.hasData {
                    var ext = try extensions.readSequence()
                    let oid = try ext.readObjectIdentifier()
                    if try ext.peekTag().value == AsnUniversal.boolean { _ = try ext.readBoolean() }
                    let value = try ext.readOctetString()
                    if oid == deltaIndicator {
                        crl.delta = true
                    } else if oid == issuingDistributionPoint {
                        crl.scope = readScope(value)
                    }
                }
            }
            return crl
        } catch {
            return nil
        }
    }

    private static func isTime(_ value: Int) -> Bool { value == AsnUniversal.utcTime || value == AsnUniversal.generalizedTime }

    private static func readScope(_ der: [UInt8]) -> Scope {
        var points: [String] = []
        var user = false, ca = false, other = false
        do {
            var outer = AsnReader(der)
            var reader = try outer.readSequence()
            let constructed = AsnTag.context(0, constructed: true)
            while reader.hasData {
                let tag = try reader.peekTag()
                if tag.tagClass != 2 { throw AsnContentException() }
                switch tag.value {
                case 0:
                    var name = try reader.readSequence(tag)
                    if try !name.hasData || !name.peekTag().hasSameClassAndValue(constructed) {
                        other = true
                        break
                    }
                    var names = try name.readSequence(constructed)
                    while names.hasData {
                        let uri = try names.peekTag()
                        if uri.tagClass == 2 && uri.value == 6 {
                            points.append(Latin1.string(try names.readOctetString(AsnTag(tagClass: 2, isConstructed: false, value: 6))))
                        } else {
                            _ = try names.readEncodedValue()
                            other = true
                        }
                    }
                case 1:
                    user = try reader.readBoolean(tag)
                case 2:
                    ca = try reader.readBoolean(tag)
                default:
                    other = true
                    _ = try reader.readEncodedValue()
                }
            }
        } catch {
            other = true
        }
        return Scope(points: points, onlyUser: user, onlyCa: ca, other: other)
    }

    private static func readTime(_ reader: inout AsnReader) throws -> DateTimeOffset {
        try reader.peekTag().value == AsnUniversal.utcTime ? reader.readUtcTime() : reader.readGeneralizedTime()
    }

    /// The list is by `issuer`, carries its signature and covers `certificate`; the status of the certificate on it. A
    /// list is complete for the certificate or says nothing: a delta list or one for other certificates never makes a
    /// certificate good. With a `time`, "good" counts only when the list holds for that time.
    func about(_ certificate: X509Certificate, _ issuer: X509Certificate, _ time: DateTimeOffset? = nil) -> (state: RevocationState, revokedAt: DateTimeOffset?) {
        if self.issuer != issuer.subjectName || certificate.issuerName != self.issuer { return (.noData, nil) }
        if !maySignLists(issuer) { return (.noData, nil) }
        let algorithm = Oids.digestName(OcspResponse.digestOf(signatureOid)) ?? .sha256
        if !CmsVerifier.verifyRaw(issuer, signatureOid, signature, tbs, algorithm) { return (.noData, nil) }
        // A name on any list its issuer signed is revoked; only a complete list can clear it.
        if let at = revoked[certificate.serialNumber] { return (.revoked, at) }
        if delta || !inScope(certificate) { return (.noData, nil) }
        if let time, !OcspResponse.covers(thisUpdate, nextUpdate, time) { return (.noData, nil) }
        return (.good, nil)
    }

    private func inScope(_ certificate: X509Certificate) -> Bool {
        guard let scope else { return true }
        let authority: Bool
        do { authority = try certificate.basicConstraints()?.certificateAuthority ?? false } catch { return false }
        if scope.other || (scope.onlyUser && authority) || (scope.onlyCa && !authority) { return false }
        return scope.points.isEmpty || CertificateLinks.crlUrls(certificate).contains { url in scope.points.contains(url) }
    }

    private func maySignLists(_ issuer: X509Certificate) -> Bool {
        do {
            guard let usage = try issuer.keyUsage() else { return true }
            return usage.contains(.crlSign)
        } catch {
            return false
        }
    }
}

/// The places a certificate says to ask: OCSP responders, CRL distribution points and the issuer's certificate.
enum CertificateLinks {
    private static let authorityInfoAccess = "1.3.6.1.5.5.7.1.1"
    private static let crlDistribution = "2.5.29.31"
    private static let ocsp = "1.3.6.1.5.5.7.48.1"
    private static let caIssuers = "1.3.6.1.5.5.7.48.2"

    static func ocspUrls(_ certificate: X509Certificate) -> [String] { accessUrls(certificate, ocsp) }

    static func issuerUrls(_ certificate: X509Certificate) -> [String] { accessUrls(certificate, caIssuers) }

    private static func accessUrls(_ certificate: X509Certificate, _ method: String) -> [String] {
        var urls: [String] = []
        guard let found = certificate.extensionNamed(authorityInfoAccess) else { return urls }
        do {
            var outer = AsnReader(found.value)
            var descriptions = try outer.readSequence()
            while descriptions.hasData {
                var description = try descriptions.readSequence()
                let oid = try description.readObjectIdentifier()
                let tag = try description.peekTag()
                if oid == method && tag.tagClass == 2 && tag.value == 6 {
                    urls.append(Latin1.string(try description.readOctetString(AsnTag(tagClass: 2, isConstructed: false, value: 6))))
                } else {
                    _ = try description.readEncodedValue()
                }
            }
        } catch {
            // An extension nobody can read points nowhere.
        }
        return urls
    }

    static func crlUrls(_ certificate: X509Certificate) -> [String] {
        var urls: [String] = []
        guard let found = certificate.extensionNamed(crlDistribution) else { return urls }
        let constructed = AsnTag.context(0, constructed: true)
        do {
            var outer = AsnReader(found.value)
            var points = try outer.readSequence()
            while points.hasData {
                var point = try points.readSequence()
                if try !point.hasData || !point.peekTag().hasSameClassAndValue(constructed) { continue }
                var name = try point.readSequence(constructed)
                if try !name.hasData || !name.peekTag().hasSameClassAndValue(constructed) { continue }
                var names = try name.readSequence(constructed)
                while names.hasData {
                    let tag = try names.peekTag()
                    if tag.tagClass == 2 && tag.value == 6 {
                        urls.append(Latin1.string(try names.readOctetString(AsnTag(tagClass: 2, isConstructed: false, value: 6))))
                    } else {
                        _ = try names.readEncodedValue()
                    }
                }
            }
        } catch {
            // As above.
        }
        return urls
    }
}
