import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/sign/SignatureRowTests.cs: the Signatures panel in plain words, and the signed
// version of a file taken out of its history. The cases that sign a file need Security.framework for the key and run on
// Apple platforms only.

final class SignatureRowTests: XCTestCase {
    private static let now = DateTimeOffset(2026, 3, 10, 9, 0, 0)

    private func allLines(_ row: SignatureRow) -> String {
        row.sections.flatMap { $0.lines }.joined(separator: "\n")
    }

    private func report(_ verdict: SignatureVerdict, _ problems: SignatureProblem...) -> SignatureReport {
        var report = SignatureReport()
        report.verdict = verdict
        report.problems = problems
        report.signerName = "Ada Lovelace"
        report.revision = 2
        report.coversWholeFile = true
        return report
    }

    private func untrusting() -> VerifyOptions {
        var options = VerifyOptions()
        options.useSystemStore = false
        options.now = Self.now
        return options
    }

    func test_aRevisionThatIsNotThereGivesNothing() {
        var missing = SignatureReport()
        missing.revision = 9

        XCTAssertNil(SignedVersion.of(Pdfs.text(), missing))
    }

    func test_aRevokedCertificateIsBadAndSaysSo() {
        let row = SignatureRow(report(.validButUntrusted, .untrustedSigner, .certificateRevoked), page: 0, area: nil)

        XCTAssertEqual(row.level, .bad)
        XCTAssertEqual(row.status, "Certificate was revoked")
        XCTAssertTrue(row.sentence.contains("Do not rely on this signature."))
    }

    func test_anotherFlawOfATrustedSignerIsNamedNotCalledUntrusted() {
        let row = SignatureRow(report(.validButUntrusted, .weakDigest), page: 0, area: nil)

        XCTAssertEqual(row.level, .caution)
        XCTAssertEqual(row.status, "Signature uses a weak digest")
    }

    func test_anUnknownSignerStaysUnknown() {
        let row = SignatureRow(report(.validButUntrusted, .untrustedSigner), page: 0, area: nil)

        XCTAssertEqual(row.status, "Signer is not trusted")
    }

    func test_onlyTheCertifyingSignatureSaysItCertified() {
        var approval = report(.valid)
        approval.kind = .approval
        approval.certification = .formFill
        var certifying = approval
        certifying.kind = .certification

        XCTAssertFalse(allLines(SignatureRow(approval, page: 0, area: nil)).contains("Certified"))
        XCTAssertTrue(allLines(SignatureRow(certifying, page: 0, area: nil)).contains("Certified: form filling is allowed."))
    }

    func test_theLevelsHaveTheirOwnSymbols() {
        let symbols = [SignatureVerdict.valid, .validButUntrusted, .broken, .unknown].map { SignatureRow(report($0), page: 0, area: nil).symbol }

        XCTAssertEqual(Set(symbols).count, 4)
    }

    func test_aSignatureWithNoNameIsNamedByItsField() {
        var unnamed = report(.valid)
        unnamed.signerName = nil
        unnamed.index = 2
        XCTAssertEqual(SignatureRow(unnamed, page: 0, area: nil).title, "Signature 3")

        unnamed.fieldName = "Approval"
        XCTAssertEqual(SignatureRow(unnamed, page: 0, area: nil).title, "Approval")
    }

    #if canImport(Security)
    private func signed(comment: Bool, trusted: Bool = false) throws -> (file: [UInt8], report: SignatureReport) {
        let ada = try PdfDigitalId.create("Ada Lovelace", nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 1, keyBits: 2048)
        let session = try PdfEditSession.open(Pdfs.text())
        var request = PdfSignRequest(ada, Self.now)
        request.reason = "Approved"
        request.fonts = FakeFonts()
        try PdfSigner.sign(session, request)
        if comment {
            _ = try PdfAnnotationWriter(session.document).addNote(session.document.pages[0], PdfRect(10, 10, 30, 30), AnnotationInfo(contents: "hi"))
            _ = try session.commit("Comment")
        }
        var options = untrusting()
        options.trustAnchors = trusted ? [ada] : []
        let file = session.current
        let reports = try PdfSignatureVerifier.verify(file, options)
        XCTAssertEqual(reports.count, 1)
        return (file, try XCTUnwrap(reports.first))
    }

    func test_anUntouchedSignatureSaysWhoAndWhatItDidNotCheck() throws {
        let (_, report) = try signed(comment: false)

        let row = SignatureRow(report, page: 0, area: nil)

        XCTAssertEqual(row.title, "Ada Lovelace")
        XCTAssertEqual(row.status, "Signer is not trusted")
        XCTAssertTrue(row.sentence.contains("Signed by Ada Lovelace on 10 Mar 2026."))
        XCTAssertEqual(row.level, .caution)
        XCTAssertTrue(allLines(row).contains("Reason: Approved"))
        XCTAssertTrue(row.sections.map { $0.heading }.contains("Not checked"))
        XCTAssertFalse(row.sections.map { $0.heading }.contains("Changed since signing"))
        XCTAssertFalse(row.hasLaterRevisions)
    }

    func test_aTrustedSignerIsGoodAndHasNoProblems() throws {
        let (_, report) = try signed(comment: false, trusted: true)

        let row = SignatureRow(report, page: 0, area: nil)

        XCTAssertEqual(row.level, .good)
        XCTAssertFalse(row.sections.map { $0.heading }.contains("Problems"))
    }

    func test_aLaterCommentIsListedAsAChangeSinceSigning() throws {
        let (_, report) = try signed(comment: true)

        let row = SignatureRow(report, page: 0, area: nil)

        XCTAssertTrue(row.hasLaterRevisions)
        let changes = try XCTUnwrap(row.sections.first { $0.heading == "Changed since signing" })
        XCTAssertTrue(changes.lines.allSatisfy { $0.contains("not allowed") })
        XCTAssertEqual(changes.lines.count, Set(changes.lines).count)
        XCTAssertEqual(row.level, .bad)
    }

    func test_theSignedVersionIsTheFileAsItWasWhenSigned() throws {
        let (file, report) = try signed(comment: true)

        let version = try XCTUnwrap(SignedVersion.of(file, report))

        XCTAssertLessThan(version.count, file.count)
        XCTAssertFalse(PdfAnnotations.readAll(try PdfDocument.open(version)).contains { $0.type == .text })
        let again = try PdfSignatureVerifier.verify(version, untrusting())
        XCTAssertEqual(again.count, 1)
        XCTAssertTrue(again[0].coversWholeFile)
        XCTAssertEqual(again[0].verdict, .validButUntrusted)
    }

    func test_aTailAfterTheSignatureLeavesTheSignedVersionToOpen() throws {
        let (file, _) = try signed(comment: false)
        let tail = file + Array("\n% added\n".utf8)
        let report = try XCTUnwrap(try PdfSignatureVerifier.verify(tail, untrusting()).first)

        let row = SignatureRow(report, page: 0, area: nil)

        XCTAssertTrue(row.hasLaterRevisions)
        XCTAssertNotNil(SignedVersion.of(tail, report))
    }

    func test_aSignatureThatClosesTheFileHasNoLaterVersion() throws {
        let (_, report) = try signed(comment: false)

        XCTAssertFalse(SignatureRow(report, page: 0, area: nil).hasLaterRevisions)
    }

    func test_aFieldIsFoundByItsFullNameAndItsFirstWidget() throws {
        let ada = try PdfDigitalId.create("Ada Lovelace", nil, DateTimeOffset(2026, 3, 9, 9, 0, 0), years: 1, keyBits: 2048)
        let session = try PdfEditSession.open(Pdfs.text(2))
        _ = try PdfForm.read(session.document).addField(FieldSpec(.signature, "Approval", 1, PdfRect(72, 100, 200, 150)))
        _ = try session.commit("Field")
        var request = PdfSignRequest(ada, Self.now)
        request.fieldName = "Approval"
        request.fonts = FakeFonts()
        try PdfSigner.sign(session, request)

        let fields = try SignatureFields.locate(session.current, nil)

        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields["Approval"]?.page, 1)
        XCTAssertEqual(fields["Approval"]?.rect, PdfRect(72, 100, 200, 150))
    }

    func test_aSignatureThatALaterUpdateUnhookedIsStillFound() throws {
        let (file, _) = try signed(comment: false)
        let session = try PdfEditSession.open(file)
        session.document.catalog.remove("AcroForm")
        _ = try session.commit("Strip")

        let reports = try PdfSignatureVerifier.verify(session.current, untrusting())

        XCTAssertEqual(reports.count, 1)
        XCTAssertFalse(session.document.isSigned)
    }
    #endif
}
