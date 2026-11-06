#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureChangeTests.cs: the same cases. The helpers the other signature
// tests share (FormFile, Certified, Edit, First) are SignatureTestHelpers in SignatureSharedRoleTests.swift.

final class SignatureChangeTests: XCTestCase {
    private let pki = Pki.instance

    private func fill(_ file: [UInt8], _ field: String = "Name") throws -> [UInt8] {
        try SignatureTestHelpers.edit(file) { d in _ = try PdfForm.read(d).setValue(field, "Ada Lovelace") }
    }

    private func retitle(_ document: PdfDocument) throws {
        var metadata = DocumentMetadata.read(document)
        metadata.title = "New title"
        try metadata.write(document)
    }

    private func comment(_ file: [UInt8]) throws -> [UInt8] {
        try SignatureTestHelpers.edit(file) { d in
            _ = try PdfAnnotationWriter(d).addNote(d.pages[0], PdfRect(250, 350, 270, 370), AnnotationInfo(author: "A", contents: "Looks fine"))
        }
    }

    private func first(_ file: [UInt8]) throws -> SignatureReport { try SignatureTestHelpers.first(file) }

    private func secondSigner(_ days: Int = 1) throws -> PdfSignRequest {
        var request = PdfSignRequest(pki.leafEc, try XCTUnwrap(Pki.signing.adding(days: days)))
        request.chain = pki.chain
        return request
    }

    func test_aFileNobodyTouchedHasNoChanges() throws {
        let report = try first(SignatureTestHelpers.certified(.noChanges))

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.isEmpty)
        XCTAssertEqual(report.sentence, "Signed by Ada Lovelace on 10 Mar 2026. Not changed since.")
    }

    func test_fillingAFormIsAllowedFromLevelTwo() throws {
        let cases: [(CertificationLevel, Bool)] = [(.noChanges, false), (.formFill, true), (.annotate, true)]
        for (level, allowed) in cases {
            let report = try first(fill(SignatureTestHelpers.certified(level)))

            XCTAssertEqual(report.verdict, allowed ? .valid : .changedAfterSigning, "\(level)")
            XCTAssertFalse(report.changes.changes.isEmpty, "\(level)")
            XCTAssertTrue(report.changes.changes.allSatisfy { $0.kind == .formFill }, "\(level)")
            XCTAssertTrue(report.changes.changes.allSatisfy { $0.allowed == allowed }, "\(level)")
            XCTAssertEqual(report.changes.changes.first { $0.field != nil }?.field, "Name", "\(level)")
            if allowed { XCTAssertTrue(report.sentence.hasSuffix("Changed only as the signer allowed."), "\(level)") }
        }
    }

    func test_commentsAreAllowedAtLevelThreeOnly() throws {
        let cases: [(CertificationLevel, Bool)] = [(.noChanges, false), (.formFill, false), (.annotate, true)]
        for (level, allowed) in cases {
            let report = try first(comment(SignatureTestHelpers.certified(level)))

            XCTAssertEqual(report.verdict, allowed ? .valid : .changedAfterSigning, "\(level)")
            XCTAssertTrue(report.changes.changes.contains { $0.kind == .comment && $0.page == 0 && $0.allowed == allowed }, "\(level)")
        }
    }

    func test_withoutCertificationOnlySignaturesAndValidationDataMayFollow() throws {
        let signed = try PdfSigner.sign(SignatureTestHelpers.formFile(), SignatureKit.request(pki))

        XCTAssertEqual(try first(fill(signed)).verdict, .changedAfterSigning)
        XCTAssertEqual(try first(comment(signed)).verdict, .changedAfterSigning)
        let report = try first(PdfSigner.sign(signed, secondSigner()))
        XCTAssertEqual(report.verdict, .valid)
    }

    func test_certificationWithoutChangesRefusesAnotherSignature() throws {
        let certified = try SignatureTestHelpers.certified(.noChanges)
        let request = try secondSigner()

        let message = SignatureExtraKit.invalidOperation(try PdfSigner.sign(certified, request))

        XCTAssertEqual(message, SignatureText.certifiedClosed)
    }

    func test_aCertificationAtLevelTwoTakesASecondSignature() throws {
        let second = try PdfSigner.sign(SignatureTestHelpers.certified(.formFill), secondSigner())

        for report in try SignatureKit.verify(second) { XCTAssertEqual(report.verdict, .valid) }
    }

    func test_aLockedFieldStaysLockedWhateverTheLevelAllows() throws {
        let onlyDate = FieldLock(.exclude, ["Date"])
        let certified = try SignatureTestHelpers.certified(.formFill, onlyDate)

        XCTAssertEqual(try first(fill(certified, "Date")).verdict, .valid)
        let report = try first(fill(certified, "Name"))
        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.changes.contains { $0.field == "Name" && !$0.allowed })
    }

    func test_aFieldLockWithIncludeAndAllNamesWhatItBinds() throws {
        let include = try SignatureTestHelpers.certified(.formFill, FieldLock(.include, ["Name"]))
        XCTAssertEqual(try first(fill(include, "Name")).verdict, .changedAfterSigning)
        XCTAssertEqual(try first(fill(include, "Date")).verdict, .valid)

        let all = try SignatureTestHelpers.certified(.formFill, FieldLock(.all, []))
        XCTAssertEqual(try first(fill(all, "Date")).verdict, .changedAfterSigning)
    }

    func test_aCommentThatIsRemovedAgainIsACommentChange() throws {
        let cases: [(CertificationLevel, Bool)] = [(.formFill, false), (.annotate, true)]
        for (level, allowed) in cases {
            var request = SignatureKit.request(pki)
            request.certify = level
            let commented = try PdfSigner.sign(comment(SignatureTestHelpers.formFile()), request)
            let removed = try SignatureTestHelpers.edit(commented) { d in
                let annotation = try XCTUnwrap(PdfAnnotations.read(d, d.pages[0]).first { $0.type == .text })
                PdfAnnotationWriter(d).delete(annotation)
            }

            let report = try first(removed)

            XCTAssertEqual(report.verdict, allowed ? .valid : .changedAfterSigning, "\(level)")
        }
    }

    func test_pagesAreNeverAllowedAndMetadataFollowsTheLevel() throws {
        for level in [CertificationLevel.formFill, .annotate] {
            let certified = try SignatureTestHelpers.certified(level)
            let added = try SignatureTestHelpers.edit(certified) { d in try PageOperations.insertBlank(d, 1, 300, 400) }
            let report = try first(added)
            XCTAssertEqual(report.verdict, .changedAfterSigning, "\(level)")
            XCTAssertTrue(report.changes.changes.contains { $0.kind == .pageStructure && !$0.allowed }, "\(level)")

            let retitled = try SignatureTestHelpers.edit(certified) { d in try self.retitle(d) }
            XCTAssertEqual(try first(retitled).verdict, .valid, "\(level)")
            XCTAssertTrue(try first(retitled).changes.changes.contains { $0.kind == .metadata }, "\(level)")
            let strict = try SignatureTestHelpers.edit(SignatureTestHelpers.certified(.noChanges)) { d in try self.retitle(d) }
            XCTAssertEqual(try first(strict).verdict, .changedAfterSigning, "\(level)")
        }
    }

    func test_changesAreListedInWords() throws {
        let report = try first(fill(SignatureTestHelpers.certified(.formFill)))

        let lines = report.changes.changes.map { SignatureText.describe($0) }

        XCTAssertTrue(lines.contains("Form filled in field Name"))
    }

    func test_revisionsAfterTheSignatureAreCounted() throws {
        let file = try comment(fill(SignatureTestHelpers.certified(.annotate)))

        let report = try first(file)

        XCTAssertEqual(report.changes.revisionsAfter, 2)
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertFalse(report.coversWholeFile)
    }

    func test_aFileWithObjectStreamsAndACrossReferenceStreamIsJudgedTheSameWay() throws {
        let packed = try PdfDocument.open(SignatureTestHelpers.formFile()).saveRewrite(PdfSaveOptions(useObjectStreams: true))
        XCTAssertTrue(try PdfDocument.open(packed).xrefIsStream)
        var request = SignatureKit.request(pki)
        request.certify = .formFill
        let certified = try PdfSigner.sign(packed, request)
        XCTAssertEqual(try first(certified).verdict, .valid)
        XCTAssertEqual(PdfRevisions.list(certified).count, 2)

        XCTAssertEqual(try first(fill(certified)).verdict, .valid)
        let attacked = try SignatureTestHelpers.edit(certified) { d in d.pages[0].dictionary["Rotate"] = PdfNumber(90) }
        XCTAssertEqual(try first(attacked).verdict, .changedAfterSigning)
        let content = try SignatureTestHelpers.edit(certified) { d in
            (d.resolve(d.pages[0].dictionary["Contents"]) as? PdfStream)?.data = TestPdf.latin("BT ET")
        }
        XCTAssertEqual(try first(content).verdict, .changedAfterSigning)
    }

    func test_aFormAndAnnotationListThatAreIndirectObjectsAreComparedAsObjects() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 5 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots 6 0 R>>")
        pdf.stream(4, "", "BT ET")
        pdf.obj(5, "<</Fields 7 0 R>>")
        pdf.obj(6, "[]")
        pdf.obj(7, "[]")
        var firstRequest = SignatureKit.request(pki)
        firstRequest.rect = PdfRect(10, 10, 100, 40)
        let signedOnce = try PdfSigner.sign(pdf.finish(), firstRequest)
        var secondRequest = try secondSigner()
        secondRequest.rect = PdfRect(10, 50, 100, 80)
        let second = try PdfSigner.sign(signedOnce, secondRequest)

        let reports = try SignatureKit.verify(second)

        for report in reports { XCTAssertEqual(report.verdict, .valid) }
        XCTAssertEqual(reports.map { $0.fieldName }, ["Signature1", "Signature2"])
        XCTAssertTrue(reports[0].changes.changes.contains { $0.kind == .signature && $0.allowed })

        let hidden = try SignatureTestHelpers.edit(signedOnce) { d in d.array(d.pages[0].dictionary, "Annots")?.items.removeAll() }
        XCTAssertEqual(try first(hidden).verdict, .changedAfterSigning)
    }
}
#endif
