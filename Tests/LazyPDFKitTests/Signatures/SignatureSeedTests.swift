#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureSeedTests.cs: the same cases.

final class SignatureSeedTests: XCTestCase {
    private let pki = Pki.instance

    private func parse(_ text: String) throws -> PdfObject {
        try PdfLexer(PdfArrayBytes(TestPdf.latin(text))).readObject()
    }

    private func fieldWith(_ seed: String) throws -> [UInt8] {
        let document = try PdfDocument.open(SignatureKit.plain())
        let field = try PdfForm.read(document).addField(FieldSpec(.signature, "Approval", 0, PdfRect(30, 30, 200, 80)))
        field.dictionary["SV"] = try parse(seed)
        return try document.saveIncremental()
    }

    private func request(_ change: ((inout PdfSignRequest) -> Void)? = nil) -> PdfSignRequest {
        var request = SignatureKit.request(pki)
        request.fieldName = "Approval"
        change?(&request)
        return request
    }

    private func hex(_ bytes: [UInt8]) -> String {
        "<" + bytes.map { String(format: "%02X", $0) }.joined() + ">"
    }

    private func sign(_ seed: String, line: UInt = #line, _ change: ((inout PdfSignRequest) -> Void)? = nil) throws -> SignatureReport {
        let reports = try SignatureKit.verify(PdfSigner.sign(fieldWith(seed), request(change)))
        XCTAssertEqual(reports.count, 1, line: line)
        return try XCTUnwrap(reports.first, line: line)
    }

    @discardableResult
    private func refused(_ seed: String, line: UInt = #line, _ change: ((inout PdfSignRequest) -> Void)? = nil) throws -> String {
        let file = try fieldWith(seed)
        var message = ""
        XCTAssertThrowsError(try PdfSigner.sign(file, request(change)), line: line) { error in
            guard let thrown = error as? InvalidOperationException else { return XCTFail("\(error)", line: line) }
            message = thrown.message
        }
        return message
    }

    func test_aRequiredSubFilterDecidesTheFormat() throws {
        let report = try sign("<</Type /SV /Ff 2 /SubFilter [/adbe.x509.rsa_sha1 /adbe.pkcs7.detached]>>")

        XCTAssertEqual(report.subFilter, "adbe.pkcs7.detached")
        XCTAssertEqual(report.verdict, .valid)
    }

    func test_aSubFilterWeCannotWriteIsRefusedWhenRequiredAndIgnoredWhenNot() throws {
        XCTAssertEqual(try refused("<</Type /SV /Ff 2 /SubFilter [/adbe.x509.rsa_sha1]>>"), SignatureText.seedFormat)
        XCTAssertEqual(try sign("<</Type /SV /SubFilter [/adbe.x509.rsa_sha1]>>").subFilter, "ETSI.CAdES.detached")
    }

    func test_requiredReasonsGiveTheFirstOneOrRefuseAnother() throws {
        let seed = "<</Type /SV /Ff 8 /Reasons [(I have reviewed this) (I approve)]>>"

        XCTAssertEqual(try sign(seed).reason, "I have reviewed this")
        XCTAssertEqual(try sign(seed) { $0.reason = "I approve" }.reason, "I approve")
        XCTAssertEqual(try refused(seed) { $0.reason = "Because" }, SignatureText.seedReason)
    }

    func test_aRequiredDigestMethodIsUsed() throws {
        let signed = try PdfSigner.sign(fieldWith("<</Type /SV /Ff 64 /DigestMethod [/SHA1 /SHA512]>>"), request())

        XCTAssertEqual(CmsSignature.parse(SignatureKit.parts(signed).cms)?.digestOid, "2.16.840.1.101.3.4.2.3")
        let reports = try SignatureKit.verify(signed)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.verdict, .valid)
        XCTAssertEqual(try refused("<</Type /SV /Ff 64 /DigestMethod [/SHA1]>>"), SignatureText.seedDigest)
    }

    func test_anMDPEntryMakesTheSignatureACertificationOfThatLevel() throws {
        let seed = "<</Type /SV /MDP <</P 2>>>>"

        let report = try sign(seed)

        XCTAssertEqual(report.kind, .certification)
        XCTAssertEqual(report.certification, .formFill)
        try refused(seed) { $0.certify = .annotate }
        try refused("<</Type /SV /MDP <</P 0>>>>") { $0.certify = .formFill }
    }

    func test_aRequiredTimeStampNeedsAServerAndTakesTheUrlFromTheField() throws {
        let seed = "<</Type /SV /TimeStamp <</URL (http://seed.test/tsa) /Ff 1>>>>"
        XCTAssertEqual(try refused(seed), SignatureText.noTimestampServer)

        let network = FakeNetwork()
        let report = try sign(seed) { $0.timestamp = TimestampSettings(network) }

        XCTAssertEqual(network.requests, ["http://seed.test/tsa"])
        XCTAssertEqual(report.level, .t)
    }

    func test_aRequiredRevocationInfoRaisesTheLevelToLT() throws {
        let seed = "<</Type /SV /Ff 32 /AddRevInfo true>>"
        try refused(seed)

        let report = try sign(seed) { $0.timestamp = TimestampSettings(FakeNetwork(), url: "http://tsa.test/") }

        XCTAssertEqual(report.level, .lt)
    }

    func test_certificateSeedValuesPickTheSigner() throws {
        XCTAssertEqual(try sign("<</Type /SV /Cert <</Ff 1 /Subject [\(hex(pki.leaf.rawData))]>>>>").verdict, .valid)
        XCTAssertEqual(try refused("<</Type /SV /Cert <</Ff 1 /Subject [\(hex(pki.leafEc.rawData))]>>>>"), SignatureText.seedCertificate)

        XCTAssertEqual(try sign("<</Type /SV /Cert <</Ff 2 /Issuer [\(hex(pki.intermediate.rawData))]>>>>").verdict, .valid)
        try refused("<</Type /SV /Cert <</Ff 2 /Issuer [\(hex(pki.selfSigned.rawData))]>>>>")
    }

    func test_subjectNamesAndKeyUsageAreMatched() throws {
        XCTAssertEqual(try sign("<</Type /SV /Cert <</Ff 8 /SubjectDN [<</CN (Ada Lovelace) /O (Lazy Test)>>]>>>>").verdict, .valid)
        try refused("<</Type /SV /Cert <</Ff 8 /SubjectDN [<</CN (Someone Else)>>]>>>>")

        XCTAssertEqual(try sign("<</Type /SV /Cert <</Ff 16 /KeyUsage [(11XXXXXXX)]>>>>").verdict, .valid)
        try refused("<</Type /SV /Cert <</Ff 16 /KeyUsage [(0XXXXXXXX)]>>>>")
    }

    func test_seedValuesTheFieldDoesNotMarkRequiredAreOnlyAdvice() throws {
        let report = try sign("<</Type /SV /Reasons [(I approve)] /DigestMethod [/SHA512] /Cert <</Subject []>>>>") { $0.reason = "Own reason" }

        XCTAssertEqual(report.reason, "Own reason")
    }

    func test_legalAttestationThatIsRequiredCannotBeMet() throws {
        XCTAssertEqual(try refused("<</Type /SV /Ff 16 /LegalAttestation [(This is legal)]>>"), SignatureText.seedUnsupported)
    }

    func test_aLockDictionaryOnTheFieldBindsTheSignature() throws {
        let document = try PdfDocument.open(SignatureKit.plain())
        let form = PdfForm.read(document)
        _ = try form.addField(FieldSpec(.text, "Name", 0, PdfRect(30, 100, 200, 124)))
        let field = try form.addField(FieldSpec(.signature, "Approval", 0, PdfRect(30, 30, 200, 80)))
        field.dictionary["Lock"] = try parse("<</Type /SigFieldLock /Action /Include /Fields [(Name)]>>")

        let signed = try PdfSigner.sign(document.saveIncremental(), request { $0.certify = .formFill })
        let filled = try SignatureTestHelpers.edit(signed) { d in _ = try PdfForm.read(d).setValue("Name", "Ada") }

        let reports = try SignatureKit.verify(filled)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.verdict, .changedAfterSigning)
    }
}
#endif
