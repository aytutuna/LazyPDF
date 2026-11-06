#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureAttackTests.cs: the same cases. Files made to make a viewer
// show something the signer never signed, and what the verifier says of them.

final class SignatureAttackTests: XCTestCase {
    private let pki = Pki.instance
    private let evil = TestPdf.latin("BT /F1 18 Tf 40 300 Td (Contract page 1: pay 1,000,000) Tj ET")

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    private func certifiedAtThree() throws -> [UInt8] { try SignatureTestHelpers.certified(.annotate) }

    private func viewerText(_ file: [UInt8]) throws -> String {
        SignatureKit.text(try PdfDocument.open(file).pages[0].contents())
    }

    private func assertNotAllowed(_ report: SignatureReport, _ kind: SignatureChangeKind, line: UInt = #line) {
        XCTAssertEqual(report.verdict, .changedAfterSigning, line: line)
        XCTAssertTrue(report.problems.contains(.changedAfterSigning), line: line)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == kind }, "\(report.changes.changes)", line: line)
        XCTAssertTrue(report.sentence.hasSuffix("Changed since."), line: line)
    }

    private func pageContent(_ document: PdfDocument) -> PdfStream? {
        document.resolve(document.pages[0].dictionary["Contents"]) as? PdfStream
    }

    func test_anIncrementalSaveThatRewritesPageContentIsCaughtEvenAtTheLoosestLevel() throws {
        let attacked = try SignatureTestHelpers.edit(certifiedAtThree()) { d in self.pageContent(d)?.data = self.evil }

        XCTAssertTrue(try viewerText(attacked).contains("pay 1,000,000"))
        assertNotAllowed(try check(attacked), .pageContent)
    }

    func test_aShadowOverlayAddedToThePageIsCaught() throws {
        let attacked = try SignatureTestHelpers.edit(certifiedAtThree()) { d in
            let page = d.pages[0]
            let overlay = try d.add(PdfStream(PdfDictionary(), data: TestPdf.latin("q 1 1 1 rg 30 280 240 50 re f Q " + Latin1.string(self.evil))))
            page.dictionary["Contents"] = PdfArray([page.dictionary["Contents"] ?? PdfNull.instance, overlay])
        }

        assertNotAllowed(try check(attacked), .pageContent)
    }

    func test_anOverlayStampIsOnlyACommentWhereCommentsAreAllowed() throws {
        let covered = try SignatureTestHelpers.edit(SignatureTestHelpers.certified(.formFill)) { d in
            _ = try PdfAnnotationWriter(d).addStamp(d.pages[0], PdfRect(30, 280, 270, 330), "Approved")
        }

        assertNotAllowed(try check(covered), .comment)
    }

    func test_hiddenContentInTheSignedFileCannotBeSwitchedOnLater() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R>>")
        pdf.stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        pdf.stream(6, "", Latin1.string(evil))
        var request = SignatureKit.request(pki)
        request.certify = .annotate
        let signed = try PdfSigner.sign(pdf.finish(), request)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(signed) { d in d.pages[0].dictionary["Contents"] = PdfReference(6, 0) }

        XCTAssertTrue(try viewerText(attacked).contains("pay 1,000,000"))
        assertNotAllowed(try check(attacked), .pageContent)
    }

    func test_anObjectThatADanglingReferenceOfTheSignedFileStartsToResolveToIsCaught() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents [4 0 R 9 0 R]>>")
        pdf.stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        var request = SignatureKit.request(pki)
        request.certify = .annotate
        let signed = try PdfSigner.sign(pdf.finish(), request)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(signed) { d in d.set(9, PdfStream(PdfDictionary(), data: self.evil)) }

        XCTAssertTrue(try viewerText(attacked).contains("pay 1,000,000"))
        XCTAssertEqual(try check(attacked).verdict, .changedAfterSigning)
    }

    // A signature that is correct for a byte range of the signer's own choosing: the digest and the CMS are made again.
    static func resign(_ file: [UInt8], _ shape: (Int, Int, Int) -> (gapStart: Int, gapEnd: Int, end: Int)) throws -> [UInt8] {
        let found = SignatureScan.find(file)[0]
        let numbers = SignatureKit.byteRange(found)
        let a = numbers[1], b = numbers[2], end = b + numbers[3]
        let (gapStart, gapEnd, newEnd) = shape(a, b, end)

        var copy = file
        let old = TestPdf.latin(String(format: "[0 %010ld %010ld %010ld]", a, b, numbers[3]))
        let rangeAt = try XCTUnwrap(copy.indexOf(old))
        let range = TestPdf.latin(String(format: "[0 %010ld %010ld %010ld]", gapStart, gapEnd, newEnd - gapEnd))
        copy.replaceSubrange(rangeAt..<rangeAt + range.count, with: range)
        let hash = Sha256.hash(Array(copy[0..<gapStart]) + Array(copy[gapEnd..<newEnd]))
        let pki = Pki.instance
        let settings = CmsSettings(certificate: pki.leaf, chain: pki.chain, digest: .sha256, cades: true, time: Pki.signing, external: nil)
        let cms = try CmsBuilder.build(hash, settings, nil)
        let hex = Array(cms.map { String(format: "%02X", $0) }.joined().utf8)
        copy.replaceSubrange(a + 1..<a + 1 + hex.count, with: hex)
        return copy
    }

    func test_aByteRangeThatStopsShortOfTheRevisionIsBrokenEvenWithAMatchingSignature() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        XCTAssertEqual(try check(Self.resign(signed) { ($0, $1, $2) }).verdict, .valid)

        let report = try check(Self.resign(signed) { ($0, $1, $2 - 40) })

        XCTAssertEqual(report.verdict, .broken)
        XCTAssertEqual(report.problems, [.badByteRange])
    }

    func test_aGapWiderThanTheContentsIsBrokenEvenWithAMatchingSignature() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))

        XCTAssertEqual(try check(Self.resign(signed) { ($0, $1 + 12, $2) }).verdict, .broken)
        XCTAssertEqual(try check(Self.resign(signed) { ($0 - 14, $1, $2) }).verdict, .broken)
    }

    func test_aByteRangeThatLeavesOutObjectsBeforeTheContentsIsBroken() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        var found = SignatureScan.find(signed)[0]
        let a = try XCTUnwrap(found.dictionary["ByteRange"] as? PdfArray).items[1]
        let start = (a as? PdfNumber)?.integer ?? 0
        let revisions = PdfRevisions.list(signed)

        // The first range must start at 0; a signature over the tail alone says nothing of the start.
        let tail = PdfDictionary()
        tail["ByteRange"] = PdfArray([PdfNumber(40), PdfNumber(start), PdfNumber(start + 10), PdfNumber(5)])
        tail["Contents"] = found.dictionary["Contents"]
        found.dictionary = tail
        XCTAssertNil(SignedRanges.check(signed, found, revisions))
    }

    func test_malformedByteRangesAreRefusedWithoutThrowing() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        let original = SignatureScan.find(signed)[0]
        for text in ["[0 10 20]", "[0 10 20 30 40 50]", "[0 -1 20 30]", "[1 10 20 30]", "[0 20 10 30]", "[0 10 20 99999999]",
                     "[0 99999999 99999999 0]", "[0.5 10 20 30]", "[]"] {
            var found = original
            let forged = PdfDictionary()
            forged["ByteRange"] = try PdfLexer(PdfArrayBytes(TestPdf.latin(text))).readObject()
            forged["Contents"] = original.dictionary["Contents"]
            found.dictionary = forged
            XCTAssertNil(SignedRanges.check(signed, found, PdfRevisions.list(signed)), text)
        }
    }

    func test_aSignatureFieldWhoseValueIsReplacedAfterSigningIsCaught() throws {
        let attacked = try SignatureTestHelpers.edit(certifiedAtThree()) { d in
            guard let field = PdfForm.read(d).fields.first(where: { $0.kind == .signature }) else { return }
            let fake = PdfDictionary()
            fake["Type"] = PdfName("Sig")
            fake["Filter"] = PdfName("Adobe.PPKLite")
            field.dictionary["V"] = try d.add(fake)
        }

        let report = try check(attacked)

        assertNotAllowed(report, .signature)
        XCTAssertEqual(report.changes.notAllowed.first { $0.kind == .signature }?.field, "Signature1")
    }

    func test_aSignatureFieldThatIsTakenOutOfTheFormIsCaught() throws {
        let attacked = try SignatureTestHelpers.edit(certifiedAtThree()) { d in
            guard let field = PdfForm.read(d).fields.first(where: { $0.kind == .signature }), let number = field.reference?.number else { return }
            let isField: (PdfObject) -> Bool = { ($0 as? PdfReference)?.number == number }
            d.array(d.dict(d.catalog, "AcroForm"), "Fields")?.items.removeAll(where: isField)
            d.array(d.pages[0].dictionary, "Annots")?.items.removeAll(where: isField)
        }

        let report = try check(attacked)

        assertNotAllowed(report, .form)
        XCTAssertNil(report.fieldName)
    }

    func test_aSignatureTheAttackerMakesOverTheChangedFileDoesNotVouchForTheSigner() throws {
        let signed = try SignatureTestHelpers.certified(.annotate)
        let changed = try SignatureTestHelpers.edit(signed) { d in self.pageContent(d)?.data = self.evil }
        var request = PdfSignRequest(pki.leafEc, Pki.signing.adding(days: 1)!)
        request.chain = pki.chain
        let resigned = try PdfSigner.sign(changed, request)

        let reports = try SignatureKit.verify(resigned)

        XCTAssertEqual(reports[0].verdict, .changedAfterSigning)
        XCTAssertEqual(reports[0].signerName, "Ada Lovelace")
        XCTAssertEqual(reports[1].verdict, .valid)
        XCTAssertEqual(reports[1].signerName, "Grace Hopper")
    }

    // A signed file whose page content exists twice: the table names the good copy, a second definition sits unused in the signed part.
    private func fileWithHiddenCopy() throws -> (signed: [UInt8], evilOffset: Int) {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R>>")
        pdf.stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        let offset = pdf.position
        let body = Latin1.string(evil)
        pdf.write("4 0 obj\n<</Length \(body.count)>>\nstream\n\(body)\nendstream\nendobj\n")
        var request = SignatureKit.request(pki)
        request.certify = .annotate
        return (try PdfSigner.sign(pdf.finish(), request), offset)
    }

    private func appendSection(_ signed: [UInt8], _ objects: String, _ entries: String, pointAtOld: Bool) throws -> [UInt8] {
        let document = try PdfDocument.open(signed)
        let prev = document.startXref
        var text = "\n" + objects
        let xref = signed.count + text.unicodeScalars.count
        text += "xref\n\(entries)trailer\n<</Size \(document.nextObjectNumber)\(SignatureRawKit.kept(document)) /Prev \(prev)>>\nstartxref\n\(pointAtOld ? prev : xref)\n%%EOF\n"
        return signed + TestPdf.latin(text)
    }

    func test_anUpdateThatOnlyPointsTheTableAtAHiddenDefinitionIsCaught() throws {
        let (signed, evilOffset) = try fileWithHiddenCopy()
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try appendSection(signed, "", "4 1\n" + String(format: "%010ld 00000 n \n", evilOffset), pointAtOld: false)

        XCTAssertTrue(try viewerText(attacked).contains("pay 1,000,000"))
        XCTAssertTrue(try PdfDocument.open(attacked).repairs.isEmpty)
        assertNotAllowed(try check(attacked), .unreadable)
    }

    func test_aBrokenTableThatSendsARepairingViewerToTheNewestCopyIsCaught() throws {
        let (signed, _) = try fileWithHiddenCopy()
        let body = Latin1.string(evil)
        let attacked = signed + TestPdf.latin("\n4 0 obj\n<</Length \(body.count)>>\nstream\n\(body)\nendstream\nendobj\nstartxref\n99999999\n%%EOF\n")

        XCTAssertTrue(try PdfDocument.open(attacked).xrefRebuilt)
        XCTAssertTrue(try viewerText(attacked).contains("pay 1,000,000"))
        assertNotAllowed(try check(attacked), .unreadable)
    }

    func test_aCopySlippedInAfterTheSignatureThatAScanningViewerWouldPickUpIsCaught() throws {
        let (signed, _) = try fileWithHiddenCopy()
        let body = Latin1.string(evil)
        let copy = "4 0 obj\n<</Length \(body.count)>>\nstream\n\(body)\nendstream\nendobj\n"

        // The final table still names the signed objects, so a table-following viewer shows the signed page.
        let attacked = try appendSection(signed, copy, "", pointAtOld: true)

        XCTAssertFalse(try viewerText(attacked).contains("pay 1,000,000"))
        assertNotAllowed(try check(attacked), .unreadable)
    }

    func test_aLaterDefinitionThatAnUpdateListsIsNotTakenForATrick() throws {
        // The same shape in an honest file: an update that rewrites the stream and lists it.
        let signed = try SignatureTestHelpers.certified(.annotate)
        let once = try SignatureTestHelpers.edit(signed) { d in
            _ = try PdfAnnotationWriter(d).addNote(d.pages[0], PdfRect(250, 350, 270, 370), AnnotationInfo(author: "A", contents: "one"))
        }
        let twice = try SignatureTestHelpers.edit(once) { d in
            _ = try PdfAnnotationWriter(d).addNote(d.pages[0], PdfRect(250, 320, 270, 340), AnnotationInfo(author: "A", contents: "two"))
        }

        XCTAssertEqual(try check(twice).verdict, .valid)
    }

    func test_aStreamThatContainsAPdfIsAnUnreferencedObjectAndNotAHiddenOne() throws {
        let signed = try SignatureTestHelpers.certified(.annotate)
        let inner = try PdfDocument.open(SignatureKit.plain()).saveIncremental()
        let attached = try SignatureTestHelpers.edit(signed) { d in _ = try d.add(PdfStream(PdfDictionary(), data: inner)) }

        assertNotAllowed(try check(attached), .other)
    }

    func test_damagedFilesNeverCrashTheVerifier() throws {
        let network = FakeNetwork()
        var request = SignatureKit.request(pki)
        request.timestamp = TimestampSettings(network, url: "http://tsa.test/")
        request.level = .lta
        let original = try PdfSigner.sign(SignatureTestHelpers.formFile(), request)
        var random = SystemRandomNumberGenerator()
        var refused = 0
        for round in 0..<300 {
            var copy = original
            for _ in 0..<Int.random(in: 1...5, using: &random) { copy[Int.random(in: 0..<copy.count, using: &random)] = UInt8.random(in: 0...255, using: &random) }
            if round % 10 == 0 { copy = Array(copy[0..<Int.random(in: 0..<copy.count, using: &random)]) }
            do {
                for report in try SignatureKit.verify(copy) { _ = report.sentence }
            } catch is PdfReadException {
                refused += 1
            }
        }
        XCTAssertLessThan(refused, 300)
    }
}
#endif
