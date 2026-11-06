#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureKit.cs: a small CA chain, a signer of each key type, a time
// stamp authority and a self-signed certificate, made once for all tests; an offline time stamp server, OCSP responder
// and CRL host; and the files the tests sign. The signature tests need Security.framework for their keys and are
// built on Apple platforms only. The certificates are written by CertificateBuilder, where the C# uses CertificateRequest.

final class Pki {
    static let ocspUrl = "http://ocsp.test/ocsp"
    static let crlUrl = "http://crl.test/intermediate.crl"
    static let rootCrlUrl = "http://crl.test/root.crl"
    static let issuerUrl = "http://ca.test/intermediate.cer"

    static let notBefore = DateTimeOffset(2025, 1, 1, 0, 0, 0)
    static let notAfter = DateTimeOffset(2040, 1, 1, 0, 0, 0)
    static let expiry = DateTimeOffset(2026, 6, 1, 0, 0, 0)

    /// A moment all certificates are valid at.
    static let signing = DateTimeOffset(2026, 3, 10, 9, 30, 0)

    static let instance = Pki()

    let root: X509Certificate
    let intermediate: X509Certificate
    let leaf: X509Certificate
    let leafEc: X509Certificate
    let tsa: X509Certificate
    let selfSigned: X509Certificate
    /// A signer whose certificate ran out on `expiry`.
    let shortLived: X509Certificate
    let chain: [X509Certificate]

    var trusting: VerifyOptions {
        var options = VerifyOptions()
        options.trustAnchors = [root]
        return options
    }

    private static var serial: UInt64 = 1000
    private static let lock = NSLock()

    private init() {
        // A failure to make a key stops every signature test at once, which is what it should do.
        do {
            root = try Self.ca("Test Root", nil)
            intermediate = try Self.ca("Test Intermediate", root)
            leaf = try Self.makeLeaf(intermediate, "Ada Lovelace", rsa: true, withLinks: true)
            leafEc = try Self.makeLeaf(intermediate, "Grace Hopper", rsa: false, withLinks: false)
            tsa = try Self.makeLeaf(intermediate, "Test Time Stamp Authority", rsa: true, withLinks: false, timestamping: true)
            selfSigned = try Self.selfSignedLeaf("Self Signer")
            shortLived = try Self.makeLeaf(intermediate, "Short Lived", rsa: true, withLinks: false, notAfter: Self.expiry)
            chain = [intermediate, root]
        } catch {
            fatalError("The test certificates could not be made: \(error)")
        }
    }

    private static func serialBytes() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        serial += 1
        return (0..<8).reversed().map { UInt8(truncatingIfNeeded: serial >> UInt64($0 * 8)) }
    }

    private static func make(_ name: String, key: SecKey, issuer: X509Certificate?, issuerKey: SecKey?, notAfter: DateTimeOffset,
                             extensions: [X509Extension]) throws -> X509Certificate {
        let subject = X509Certificate.name(name)
        let info = try CertificateBuilder.publicKeyInfo(key)
        let der = try CertificateBuilder.build(subject: subject, issuer: issuer?.subjectName ?? subject, publicKeyInfo: info,
                                               notBefore: notBefore, notAfter: notAfter,
                                               serial: issuer == nil ? CertificateBuilder.serialNumber() : serialBytes(),
                                               extensions: extensions, issuerKey: issuerKey ?? key)
        guard let certificate = X509Certificate(der) else { throw SignatureCryptoException(message: "The certificate does not read.") }
        certificate.privateKey = key
        return certificate
    }

    private static func ca(_ name: String, _ issuer: X509Certificate?) throws -> X509Certificate {
        let key = try SignatureCrypto.newRsaKey(2048)
        let info = try CertificateBuilder.publicKeyInfo(key)
        var extensions = [
            CertificateBuilder.basicConstraints(authority: true),
            CertificateBuilder.keyUsage([.keyCertSign, .crlSign]),
            CertificateBuilder.subjectKeyIdentifier(info),
        ]
        if issuer != nil { extensions.append(crlDistribution(rootCrlUrl)) }
        return try make("CN=\(name)", key: key, issuer: issuer, issuerKey: issuer?.privateKey, notAfter: notAfter, extensions: extensions)
    }

    private static func makeLeaf(_ issuer: X509Certificate, _ name: String, rsa: Bool, withLinks: Bool, timestamping: Bool = false,
                                 notAfter: DateTimeOffset? = nil) throws -> X509Certificate {
        let key = rsa ? try SignatureCrypto.newRsaKey(2048) : try SignatureCrypto.newEcKey()
        let info = try CertificateBuilder.publicKeyInfo(key)
        var extensions = [
            CertificateBuilder.basicConstraints(authority: false),
            CertificateBuilder.keyUsage([.digitalSignature, .nonRepudiation]),
            CertificateBuilder.subjectKeyIdentifier(info),
        ]
        if timestamping { extensions.append(CertificateBuilder.enhancedKeyUsage(["1.3.6.1.5.5.7.3.8"], critical: true)) }
        if withLinks {
            extensions.append(authorityInfoAccess())
            extensions.append(crlDistribution(crlUrl))
        }
        return try make("CN=\(name), O=Lazy Test", key: key, issuer: issuer, issuerKey: issuer.privateKey, notAfter: notAfter ?? Self.notAfter, extensions: extensions)
    }

    /// A certificate under the intermediate with the given key usage and purposes, for those that must not count as a signer, a time stamp authority or an OCSP responder.
    func issued(_ name: String, _ usage: KeyUsage, _ purposes: String...) throws -> X509Certificate {
        try issue(name, usage, Self.notAfter, nil, purposes)
    }

    /// Like `issued`, valid until `notAfter`.
    func issuedUntil(_ notAfter: DateTimeOffset, _ name: String, _ usage: KeyUsage, _ purposes: String...) throws -> X509Certificate {
        try issue(name, usage, notAfter, nil, purposes)
    }

    /// A certificate for signing that also carries `extension`, which may not decode.
    func issuedWith(_ name: String, _ extension: X509Extension) throws -> X509Certificate {
        try issue(name, .digitalSignature, Self.notAfter, `extension`, [])
    }

    private func issue(_ name: String, _ usage: KeyUsage, _ notAfter: DateTimeOffset, _ extra: X509Extension?, _ purposes: [String]) throws -> X509Certificate {
        let key = try SignatureCrypto.newRsaKey(2048)
        var extensions: [X509Extension] = []
        if extra?.oid != "2.5.29.19" { extensions.append(CertificateBuilder.basicConstraints(authority: false)) }
        if extra?.oid != "2.5.29.15" { extensions.append(CertificateBuilder.keyUsage(usage)) }
        if !purposes.isEmpty { extensions.append(CertificateBuilder.enhancedKeyUsage(purposes)) }
        if let extra { extensions.append(extra) }
        return try Self.make("CN=\(name), O=Lazy Test", key: key, issuer: intermediate, issuerKey: intermediate.privateKey, notAfter: notAfter, extensions: extensions)
    }

    private static func selfSignedLeaf(_ name: String) throws -> X509Certificate {
        let key = try SignatureCrypto.newRsaKey(2048)
        return try make("CN=\(name)", key: key, issuer: nil, issuerKey: nil, notAfter: notAfter,
                        extensions: [CertificateBuilder.keyUsage([.digitalSignature])])
    }

    private static func authorityInfoAccess() -> X509Extension {
        let descriptions = [("1.3.6.1.5.5.7.48.1", ocspUrl), ("1.3.6.1.5.5.7.48.2", issuerUrl)].map { oid, url in
            DerWriter.sequence([DerWriter.oid(oid), DerWriter.ia5String(url, tag: 0x86)])
        }
        return X509Extension(oid: "1.3.6.1.5.5.7.1.1", critical: false, value: DerWriter.sequence(descriptions))
    }

    static func crlDistribution(_ url: String) -> X509Extension {
        let name = DerWriter.context(0, constructed: true, DerWriter.context(0, constructed: true, DerWriter.ia5String(url, tag: 0x86)))
        return X509Extension(oid: "2.5.29.31", critical: false, value: DerWriter.sequence([DerWriter.sequence([name])]))
    }
}

/// Test code reads the serial of a certificate the way the C# reads `SerialNumberBytes`.
extension X509Certificate {
    var serialBytes: [UInt8] { serialNumber.magnitude }
}

/// A byte range, a time stamp server, an OCSP responder and a CRL host in one transport, offline.
final class FakeNetwork: SignatureTransport {
    private let pki = Pki.instance

    var stampTime = Pki.signing.adding(minutes: 1)!
    var revoked = false
    var revokedAt = Pki.signing.adding(days: -1)!
    var ocspDown = false
    var crlDown = false
    var stampDown = false

    /// The certificate that signs the OCSP answers when it is not the issuer; it is carried in the answer.
    var responder: X509Certificate?

    /// The certificate that signs the time stamps when it is not the test authority.
    var stampCertificate: X509Certificate?

    /// When the OCSP answers and the CRL were issued.
    var issued = Pki.signing.adding(days: 1)!

    var nextUpdate: DateTimeOffset?

    /// The thisUpdate of the OCSP answers when it is not `issued`.
    var ocspThisUpdate: DateTimeOffset?

    var crlExtension: X509Extension?
    var requests: [String] = []

    func post(_ url: String, _ contentType: String, _ body: [UInt8]) -> [UInt8]? {
        requests.append(url)
        if url == Pki.ocspUrl { return ocspDown ? nil : ocsp(body) }
        if stampDown { return nil }
        return stamp(body)
    }

    func get(_ url: String) -> [UInt8]? {
        requests.append(url)
        if url == Pki.issuerUrl { return pki.intermediate.rawData }
        if url == Pki.rootCrlUrl { return crl(pki.root, nil, Pki.notAfter, Pki.signing.adding(days: 1)!, []) }
        if url != Pki.crlUrl || crlDown { return nil }
        let entries = revoked ? [(pki.leaf.serialNumber, revokedAt)] : []
        return crl(pki.intermediate, crlExtension, nextUpdate ?? Pki.notAfter, issued, entries)
    }

    // The framework's builder takes no extensions, so a list is written out here; the standard list carries a number.
    private func crl(_ issuer: X509Certificate, _ extra: X509Extension?, _ next: DateTimeOffset, _ thisUpdate: DateTimeOffset,
                     _ entries: [(AsnInteger, DateTimeOffset)]) -> [UInt8] {
        var items = [
            DerWriter.integer(1),
            CmsBuilder.algorithmIdentifier("1.2.840.113549.1.1.11", withNull: true),
            issuer.subjectName,
            DerWriter.utcTime(thisUpdate),
            DerWriter.utcTime(next),
        ]
        if !entries.isEmpty {
            items.append(DerWriter.sequence(entries.map { DerWriter.sequence([DerWriter.integer($0.0), DerWriter.utcTime($0.1)]) }))
        }
        let extension_ = extra ?? X509Extension(oid: "2.5.29.20", critical: false, value: DerWriter.integer(1))
        items.append(DerWriter.context(0, constructed: true, DerWriter.sequence([
            DerWriter.sequence([DerWriter.oid(extension_.oid)] + (extension_.critical ? [DerWriter.boolean(true)] : []) + [DerWriter.octetString(extension_.value)]),
        ])))
        let body = DerWriter.sequence(items)
        guard let key = issuer.privateKey, let signature = try? SignatureCrypto.sign(key, Sha256.hash(body), .sha256, ec: false) else { return [] }
        return DerWriter.sequence([body, CmsBuilder.algorithmIdentifier("1.2.840.113549.1.1.11", withNull: true), DerWriter.bitString(signature)])
    }

    private func stamp(_ request: [UInt8]) -> [UInt8]? {
        guard let parsed = Rfc3161Request.tryDecode(request) else { return nil }
        var info = [
            DerWriter.integer(1),
            DerWriter.oid("1.2.3.4.1"),
            DerWriter.sequence([CmsBuilder.algorithmIdentifier(parsed.hashOid, withNull: true), DerWriter.octetString(parsed.messageHash)]),
            DerWriter.integer(77),
            DerWriter.generalizedTime(stampTime),
        ]
        if let nonce = parsed.nonce { info.append(DerWriter.integer(nonce)) }
        let authority = stampCertificate ?? pki.tsa
        guard let cms = TestCms.signed(contentType: Oids.tstInfo, content: DerWriter.sequence(info), signer: authority,
                                       certificates: [authority] + pki.chain) else { return nil }
        return DerWriter.sequence([DerWriter.sequence([DerWriter.integer(0)]), cms])
    }

    private func ocsp(_ request: [UInt8]) -> [UInt8]? {
        do {
            var outer = AsnReader(request)
            var list = try outer.readSequence()
            var tbs = try list.readSequence()
            if try tbs.peekTag().tagClass == 2 { _ = try tbs.readEncodedValue() }
            var requests = try tbs.readSequence()
            var single = try requests.readSequence()
            var id = try single.readSequence()
            _ = try id.readSequence()
            _ = try id.readOctetString()
            _ = try id.readOctetString()
            let serial = try id.readInteger()
            let issuer = pki.intermediate
            guard serial == pki.leaf.serialNumber else { return nil }

            let responderCertificate = responder ?? issuer
            var status: [UInt8]
            if revoked {
                status = DerWriter.context(1, constructed: true, DerWriter.generalizedTime(revokedAt))
            } else {
                status = [0x80, 0x00]
            }
            var singleResponse = [
                DerWriter.sequence([
                    CmsBuilder.algorithmIdentifier("1.3.14.3.2.26", withNull: true),
                    DerWriter.octetString(Sha1.hash(issuer.subjectName)),
                    DerWriter.octetString(Sha1.hash(issuer.encodedKeyValue)),
                    DerWriter.integer(serial),
                ]),
                status,
                DerWriter.generalizedTime(ocspThisUpdate ?? issued),
            ]
            if let next = nextUpdate { singleResponse.append(DerWriter.context(0, constructed: true, DerWriter.generalizedTime(next))) }
            let data = DerWriter.sequence([
                DerWriter.context(1, constructed: true, responderCertificate.subjectName),
                DerWriter.generalizedTime(issued),
                DerWriter.sequence([DerWriter.sequence(singleResponse)]),
            ])
            guard let key = responderCertificate.privateKey else { return nil }
            let signature = try SignatureCrypto.sign(key, Sha256.hash(data), .sha256, ec: false)
            var basicItems = [data, CmsBuilder.algorithmIdentifier("1.2.840.113549.1.1.11", withNull: true), DerWriter.bitString(signature)]
            if let responder {
                basicItems.append(DerWriter.context(0, constructed: true, DerWriter.sequence([responder.rawData])))
            }
            let basic = DerWriter.sequence(basicItems)
            return DerWriter.sequence([
                DerWriter.enumerated(0),
                DerWriter.context(0, constructed: true, DerWriter.sequence([DerWriter.oid("1.3.6.1.5.5.7.48.1.1"), DerWriter.octetString(basic)])),
            ])
        } catch {
            return nil
        }
    }
}

/// What SignedCms does for the tests: a CMS SignedData with its content inside, signed with an RSA key.
enum TestCms {
    static func signed(contentType: String, content: [UInt8], signer: X509Certificate, certificates: [X509Certificate]) -> [UInt8]? {
        guard let key = signer.privateKey else { return nil }
        let attributes = [
            DerWriter.sequence([DerWriter.oid(Oids.contentType), DerWriter.setOf([DerWriter.oid(contentType)])]),
            DerWriter.sequence([DerWriter.oid(Oids.messageDigest), DerWriter.setOf([DerWriter.octetString(Sha256.hash(content))])]),
            DerWriter.sequence([DerWriter.oid(Oids.signingCertificateV2), DerWriter.setOf([CmsBuilder.signingCertificate(signer)])]),
        ]
        guard let signature = try? SignatureCrypto.sign(key, Sha256.hash(DerWriter.setOf(attributes)), .sha256, ec: false) else { return nil }
        let signerInfo = DerWriter.sequence([
            DerWriter.integer(1),
            DerWriter.sequence([signer.issuerName, DerWriter.integer(signer.serialNumber)]),
            CmsBuilder.algorithmIdentifier("2.16.840.1.101.3.4.2.1", withNull: true),
            DerWriter.setOf(attributes, tag: 0xA0),
            CmsBuilder.algorithmIdentifier(Oids.rsaEncryption, withNull: true),
            DerWriter.octetString(signature),
        ])
        let data = DerWriter.sequence([
            DerWriter.integer(3),
            DerWriter.set([CmsBuilder.algorithmIdentifier("2.16.840.1.101.3.4.2.1", withNull: true)]),
            DerWriter.sequence([DerWriter.oid(contentType), DerWriter.context(0, constructed: true, DerWriter.octetString(content))]),
            DerWriter.setOf(certificates.map { $0.rawData }, tag: 0xA0),
            DerWriter.set([signerInfo]),
        ])
        return DerWriter.sequence([DerWriter.oid(Oids.signedData), DerWriter.context(0, constructed: true, data)])
    }
}

enum SignatureKit {
    /// Two pages and a font, built the way the other tests build files.
    static func plain(_ pages: Int = 2) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        let kids = (0..<pages).map { "\(4 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages) /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        for i in 0..<pages {
            pdf.obj(4 + i, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 3 0 R>>>> /Contents \(4 + pages + i) 0 R>>")
        }
        for i in 0..<pages { pdf.stream(4 + pages + i, "", "BT /F1 18 Tf 40 300 Td (Contract page \(i + 1)) Tj ET") }
        return pdf.finish()
    }

    static func request(_ pki: Pki) -> PdfSignRequest {
        var request = PdfSignRequest(pki.leaf, Pki.signing)
        request.chain = pki.chain
        return request
    }

    static func verify(_ file: [UInt8]) throws -> [SignatureReport] {
        try PdfSignatureVerifier.verify(file, Pki.instance.trusting)
    }

    /// The bytes of /Contents and the file without them, as openssl and other tools take them.
    static func parts(_ file: [UInt8], _ signature: Int = 0) -> (cms: [UInt8], signed: [UInt8]) {
        let found = SignatureScan.find(file)[signature]
        let n = byteRange(found)
        let signed = Array(file[n[0]..<n[0] + n[1]]) + Array(file[n[2]..<n[2] + n[3]])
        let contents = (found.dictionary["Contents"] as! PdfString).bytes
        let cms = CmsSignature.parse(contents)!
        return (Array(contents[0..<cms.length]), signed)
    }

    static func byteRange(_ found: FoundSignature) -> [Int] {
        (found.dictionary["ByteRange"] as! PdfArray).items.map { Int(($0 as! PdfNumber).value) }
    }

    /// The file with the signature in its first field replaced by `make`'s CMS over the signed bytes.
    static func splice(_ file: [UInt8], _ make: ([UInt8]) -> [UInt8]) -> [UInt8] {
        var copy = file
        let signed = parts(copy).signed
        let cms = make(signed)
        let range = byteRange(SignatureScan.find(copy)[0])
        for i in (range[1] + 1)..<(range[2] - 1) { copy[i] = UInt8(ascii: "0") }
        let hex = Array(cms.map { String(format: "%02X", $0) }.joined().utf8)
        copy.replaceSubrange(range[1] + 1..<range[1] + 1 + hex.count, with: hex)
        return copy
    }

    static func text(_ bytes: [UInt8]) -> String { Latin1.string(bytes) }
}

/// Updates written by hand: object streams, cross-reference streams and tables the writer would never make.
enum SignatureRawKit {
    static let evil = "BT /F1 18 Tf 40 300 Td (pay 1,000,000) Tj ET"
    static let form = "/Type /XObject /Subtype /Form /BBox [0 0 300 400]"

    static func streamBody(_ data: String, _ extra: String = "") -> String { "<<\(extra) /Length \(data.unicodeScalars.count)>>\nstream\n\(data)\nendstream" }

    static func showsEvil(_ file: [UInt8]) throws -> Bool {
        let document = try PdfDocument.open(file)
        return SignatureKit.text(try document.pages[0].contents()).contains("pay 1,000,000")
    }

    /// What a trailer of an update repeats from the file it follows: the catalog, and the information and identity when there are any.
    static func kept(_ document: PdfDocument) -> String {
        " /Root \(document.trailer["Root"]?.description ?? "")" + identity(document)
    }

    static func identity(_ document: PdfDocument) -> String {
        ["Info", "ID", "Encrypt"].filter { document.trailer[$0] != nil }.map { " /\($0) \(document.trailer[$0]?.description ?? "")" }.joined()
    }

    static func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    /// The first signature reads as changed and the reason is that the update's bytes cannot be placed exactly.
    static func assertUnreadable(_ file: [UInt8], file path: StaticString = #filePath, line: UInt = #line) throws {
        let report = try check(file)
        XCTAssertEqual(report.verdict, .changedAfterSigning, file: path, line: line)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .unreadable }, file: path, line: line)
    }

    /// The strict reader accepts what follows the first signature's bytes: the same bytes with the update's body judged by the rules.
    static func passesGate(_ file: [UInt8]) throws -> Bool {
        let found = SignatureScan.find(file).sorted { $0.offset < $1.offset }[0]
        let ranges = SignatureKit.byteRange(found)
        let end = ranges[2] + ranges[3]
        return UpdateGate.check(try PdfDocument.open(Array(file[0..<end])), try PdfDocument.open(file)) != nil
    }

    /// An update of `objects` with a table, whose trailer repeats what the file's does and adds `extra`; `size` is /Size
    /// when the right one is not wanted.
    static func append(_ file: [UInt8], _ extra: String, _ size: Int?, _ objects: [(number: Int, body: String)]) throws -> [UInt8] {
        let document = try PdfDocument.open(file)
        var text = "\n"
        var offsets: [(Int, Int)] = []
        for (number, body) in objects {
            offsets.append((number, file.count + text.unicodeScalars.count))
            text += "\(number) 0 obj\n\(body)\nendobj\n"
        }
        let xref = file.count + text.unicodeScalars.count
        text += "xref\n0 1\n0000000000 65535 f \n"
        for (number, offset) in offsets.sorted(by: { $0.0 < $1.0 }) { text += "\(number) 1\n" + String(format: "%010ld 00000 n \n", offset) }
        let highest = objects.map { $0.number }.max() ?? 0
        text += "trailer\n<</Size \(size ?? max(document.nextObjectNumber, highest + 1))\(kept(document)) /Prev \(document.startXref)\(extra)>>\nstartxref\n\(xref)\n%%EOF\n"
        return file + TestPdf.latin(text)
    }

    // A cross-reference stream entry of widths 1, 4 and 2.
    private static func entry(_ type: Int, _ second: Int, _ third: Int) -> String {
        let units: [UInt8] = [UInt8(type), UInt8(second >> 24 & 255), UInt8(second >> 16 & 255), UInt8(second >> 8 & 255), UInt8(second & 255),
                              UInt8(third >> 8 & 255), UInt8(third & 255)]
        return Latin1.string(units)
    }

    /// An update with `plain` objects, an object stream 40 holding `data` that lists object `member` as its entry
    /// number `index`, and a cross-reference stream 41.
    static func withObjectStream(_ signed: [UInt8], _ data: String, _ count: Int, _ first: Int, _ member: Int, _ index: Int,
                                 _ plain: [(number: Int, body: String)] = []) throws -> [UInt8] {
        let document = try PdfDocument.open(signed)
        var text = "\n"
        var entries: [Int: String] = [:]
        for (number, body) in plain {
            entries[number] = entry(1, signed.count + text.unicodeScalars.count, 0)
            text += "\(number) 0 obj\n\(body)\nendobj\n"
        }
        entries[member] = entry(2, 40, index)
        entries[40] = entry(1, signed.count + text.unicodeScalars.count, 0)
        text += "40 0 obj\n<</Type /ObjStm /N \(count) /First \(first) /Length \(data.unicodeScalars.count)>>\nstream\n\(data)\nendstream\nendobj\n"
        let table = signed.count + text.unicodeScalars.count
        entries[41] = entry(1, table, 0)
        let keys = entries.keys.sorted()
        let rows = keys.map { entries[$0] ?? "" }.joined()
        let ranges = keys.map { "\($0) 1" }.joined(separator: " ")
        text += "41 0 obj\n<</Type /XRef /Size \(max(document.nextObjectNumber, (keys.max() ?? 0) + 1)) /W [1 4 2] /Index [\(ranges)] \(kept(document)) /Prev \(document.startXref) /Length \(rows.unicodeScalars.count)>>\nstream\n\(rows)\nendstream\nendobj\nstartxref\n\(table)\n%%EOF\n"
        return signed + TestPdf.latin(text)
    }
}
#endif
