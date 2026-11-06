#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureForgeryTests.cs: the same cases. Updates that borrow,
// shadow or reorder what a signature covers, and revocation data that says less than it seems to.

final class SignatureForgeryTests: XCTestCase {
    private let pki = Pki.instance

    private let evil = TestPdf.latin("BT /F1 18 Tf 40 300 Td (Contract page 1: pay 1,000,000) Tj ET")

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    private func sign(_ pdf: TestPdf, _ level: CertificationLevel, _ fieldLock: FieldLock? = nil) throws -> [UInt8] {
        try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest { $0.certify = level; $0.lock = fieldLock })
    }

    private func viewerText(_ file: [UInt8]) throws -> String {
        SignatureKit.text(try PdfDocument.open(file).pages[0].contents())
    }

    // A page with the font of the other tests; each test adds what it needs from number 6 on.
    private func base(catalog: String = "", pages: String = "", page: String = "") -> TestPdf {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400] \(pages)>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R \(page)>>")
        pdf.stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        return pdf
    }

    static func appendSection(_ signed: [UInt8], _ objects: String, _ entries: String) throws -> [UInt8] {
        let document = try PdfDocument.open(signed)
        var text = "\n" + objects
        let xref = signed.count + text.unicodeScalars.count
        text += "xref\n\(entries)trailer\n<</Size \(document.nextObjectNumber)\(SignatureRawKit.kept(document)) /Prev \(document.startXref)>>\nstartxref\n\(xref)\n%%EOF\n"
        return signed + TestPdf.latin(text)
    }

    private func streamObject(_ number: Int, _ body: String) -> String {
        "\(number) 0 obj\n<</Length \(body.unicodeScalars.count)>>\nstream\n\(body)\nendstream\nendobj\n"
    }

    private func assertChanged(_ report: SignatureReport, _ kind: SignatureChangeKind, line: UInt = #line) {
        XCTAssertEqual(report.verdict, .changedAfterSigning, line: line)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == kind }, line: line)
    }

    // ---- a signature that is not new

    func test_aWidgetThatPointsAtTheSignedSignatureIsNotANewSignature() throws {
        let cases: [(CertificationLevel, Bool)] = [(.formFill, true), (.annotate, true), (.formFill, false), (.annotate, false)]
        for (level, listedInForm) in cases {
            let signed = try SignatureTestHelpers.certified(level)

            let attacked = try SignatureTestHelpers.edit(signed) { d in
                let victim = try SignatureObjects.signatureField(d)
                let widget = try d.add(SignatureObjects.entries(
                    ("Type", PdfName("Annot")),
                    ("Subtype", PdfName("Widget")),
                    ("FT", PdfName("Sig")),
                    ("T", SignatureObjects.text("Cover")),
                    ("Rect", SignatureObjects.numbers(0, 0, 300, 400)),
                    ("V", try XCTUnwrap(victim.dictionary["V"]))))
                try SignatureObjects.annots(d).items.append(widget)
                if listedInForm { try XCTUnwrap(d.array(d.dict(d.catalog, "AcroForm"), "Fields")).items.append(widget) }
            }

            XCTAssertEqual(try check(attacked).verdict, .changedAfterSigning, "\(level) \(listedInForm)")
        }
    }

    func test_aWidgetThatOnlyNamesTheSignedFieldAsItsParentIsNotANewSignature() throws {
        let attacked = try SignatureTestHelpers.edit(SignatureTestHelpers.certified(.annotate)) { d in
            let victim = try SignatureObjects.signatureField(d)
            let widget = try d.add(SignatureObjects.entries(
                ("Type", PdfName("Annot")),
                ("Subtype", PdfName("Widget")),
                ("Parent", try XCTUnwrap(victim.reference)),
                ("Rect", SignatureObjects.numbers(0, 0, 300, 400))))
            try SignatureObjects.annots(d).items.append(widget)
        }

        XCTAssertEqual(try check(attacked).verdict, .changedAfterSigning)
    }

    func test_aSecondSignatureAddedBySigningAgainIsStillANewSignature() throws {
        let second = try SignatureObjects.second(SignatureTestHelpers.certified(.formFill))

        for report in try SignatureKit.verify(second) { XCTAssertEqual(report.verdict, .valid) }
    }

    func test_aSignatureWhoseContentsAreNoSignatureDoesNotCountAsAdded() throws {
        let second = try SignatureObjects.second(SignatureTestHelpers.certified(.formFill))
        var garbled = second
        let range = SignatureKit.byteRange(SignatureScan.find(garbled)[1])
        for i in (range[1] + 1)..<(range[2] - 1) { garbled[i] = UInt8(ascii: "0") }
        garbled.replaceSubrange(range[1] + 1..<range[1] + 81, with: [UInt8](repeating: UInt8(ascii: "0"), count: 80))

        let reports = try SignatureKit.verify(garbled)

        XCTAssertEqual(reports[1].verdict, .broken)
        XCTAssertEqual(reports[0].verdict, .changedAfterSigning)
    }

    // ---- objects the signed revision could not read

    func test_anEntryPastTheEndOfTheSignedRevisionCannotBeFilledInLater() throws {
        let pdf = base(page: "")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents [4 0 R 9 0 R]>>")
        let file = TestPdf.replace(TestPdf.replace(pdf.finish(), "xref\n0 6\n", "xref\n0 10\n"), "trailer\n<</Size 6",
                                   "0000000000 00000 f \n0000000000 00000 f \n0000000000 00000 f \n0000200000 00000 n \ntrailer\n<</Size 10")
        let signed = try PdfSigner.sign(file, SignatureObjects.leafRequest { $0.certify = .annotate })
        XCTAssertEqual(try check(signed).verdict, .valid)

        let padded = signed + [UInt8](repeating: UInt8(ascii: " "), count: 199_999 - signed.count)
        let attacked = try Self.appendSection(padded, streamObject(9, Latin1.string(evil)), "")

        XCTAssertTrue(try viewerText(attacked).contains("pay 1,000,000"))
        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aStreamThatOnlyEndsPastTheSignedRevisionCannotGrowLater() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R>>")
        pdf.stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET", length: 200_000, endstream: false)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        let signed = try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest { $0.certify = .annotate })
        XCTAssertEqual(try check(signed).verdict, .valid)

        let stream = try XCTUnwrap(PdfDocument.open(signed).get(4) as? PdfStream)
        let end = stream.dataOffset + 200_000
        var tail = TestPdf.latin("\n")
        tail += [UInt8](repeating: UInt8(ascii: " "), count: max(0, end - signed.count - 1 - evil.count))
        tail += evil
        let grown = signed + tail + TestPdf.latin("\nendstream\nendobj\n")
        let attacked = try Self.appendSection(grown, "", "")

        XCTAssertTrue(try viewerText(attacked).contains("pay 1,000,000"))
        XCTAssertEqual(try check(attacked).verdict, .changedAfterSigning)
    }

    // ---- direct entries of /Annots

    private func directAnnots(_ level: CertificationLevel) throws -> [UInt8] {
        try sign(base(page: "/Annots [<</Subtype /Square /Rect [0 0 1 1]>>]"), level)
    }

    func test_aDirectAnnotationSwappedForAnotherIsAComment() throws {
        for level in [CertificationLevel.noChanges, .formFill] {
            let attacked = try SignatureTestHelpers.edit(directAnnots(level)) { d in
                let cover = SignatureObjects.entries(
                    ("Subtype", PdfName("FreeText")),
                    ("Rect", SignatureObjects.numbers(0, 0, 300, 400)),
                    ("Contents", SignatureObjects.text("VOID")))
                try SignatureObjects.annots(d).items[0] = cover
            }

            assertChanged(try check(attacked), .comment)
        }
    }

    func test_reorderingTheAnnotationsOfAPageChangesWhatIsOnTop() throws {
        let pdf = base(page: "/Annots [6 0 R 7 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Square /Rect [0 0 50 50]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Circle /Rect [0 0 50 50]>>")
        let signed = try sign(pdf, .formFill)

        let attacked = try SignatureTestHelpers.edit(signed) { d in try SignatureObjects.annots(d).items.reverse() }

        assertChanged(try check(attacked), .comment)
    }

    func test_reorderingTheAnnotationsIsACommentThatLevelThreeAllows() throws {
        let pdf = base(page: "/Annots [6 0 R 7 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Square /Rect [0 0 50 50]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Circle /Rect [0 0 50 50]>>")
        let signed = try sign(pdf, .annotate)

        let attacked = try SignatureTestHelpers.edit(signed) { d in try SignatureObjects.annots(d).items.reverse() }

        XCTAssertEqual(try check(attacked).verdict, .valid)
    }

    // ---- which rule an object that serves twice follows

    func test_aStreamThatIsMetadataAndPageContentFollowsThePageContentRule() throws {
        let signed = try sign(base(catalog: "/Metadata 4 0 R"), .formFill)

        let attacked = try SignatureTestHelpers.edit(signed) { d in try SignatureObjects.stream(d, 4).data = self.evil }

        assertChanged(try check(attacked), .pageContent)
    }

    func test_aStreamThatIsPageContentAndListedAsAnAnnotationFollowsThePageContentRule() throws {
        let signed = try sign(base(page: "/Annots [4 0 R]"), .annotate)

        let attacked = try SignatureTestHelpers.edit(signed) { d in try SignatureObjects.stream(d, 4).data = self.evil }

        assertChanged(try check(attacked), .pageContent)
    }

    func test_aSignedFieldReplacedBySomethingThatIsNoDictionaryIsCaught() throws {
        for stream in [true, false] {
            let signed = try SignatureTestHelpers.certified(.annotate)

            let attacked = try SignatureTestHelpers.edit(signed) { d in
                let field = try SignatureObjects.signatureField(d)
                let value: PdfObject = stream ? PdfStream(field.dictionary.copy(), data: self.evil) : PdfNull.instance
                d.set(try XCTUnwrap(field.reference).number, value)
            }

            XCTAssertEqual(try check(attacked).verdict, .changedAfterSigning, "\(stream)")
        }
    }

    func test_resourcesAPageInheritsArePageContent() throws {
        let pdf = base(catalog: "/AcroForm <</Fields [6 0 R]>>", pages: "/Resources <</Font <</F1 5 0 R>>>>", page: "/Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Free) /Rect [20 20 120 40] /AP <</N 7 0 R>>>>")
        pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 100 20] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 10 Tf (x) Tj ET")
        let signed = try sign(pdf, .formFill)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(signed) { d in try SignatureObjects.dictionary(d, 5)["BaseFont"] = PdfName("Courier") }

        assertChanged(try check(attacked), .pageContent)
    }

    func test_anAppearanceTwoFieldsShareFollowsTheStricterField() throws {
        let pdf = base(catalog: "/AcroForm <</Fields [6 0 R 8 0 R]>>", page: "/Annots [6 0 R 8 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Free) /Rect [20 20 120 40] /AP <</N 7 0 R>>>>")
        pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 100 20]", "BT /F1 10 Tf (1) Tj ET")
        pdf.obj(8, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /Rect [20 60 120 80] /AP <</N 7 0 R>>>>")
        let signed = try sign(pdf, .formFill, FieldLock(.include, ["Amount"]))
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(signed) { d in
            try SignatureObjects.stream(d, 7).data = TestPdf.latin("BT /F1 10 Tf (999999) Tj ET")
        }

        assertChanged(try check(attacked), .formFill)
    }

    // ---- validation data

    func test_onlyTheDataADSSNamesMayChangeAsValidationData() throws {
        let pdf = base(catalog: "/DSS <</X 6 0 R>> /OCProperties <</OCGs [7 0 R] /D 6 0 R>>")
        pdf.obj(6, "<</Order [7 0 R]>>")
        pdf.obj(7, "<</Type /OCG /Name (Layer)>>")
        let signed = try sign(pdf, .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(signed) { d in
            try SignatureObjects.dictionary(d, 6)["OFF"] = PdfArray([PdfReference(7, 0)])
        }

        XCTAssertEqual(try check(attacked).verdict, .changedAfterSigning)
    }

    // ---- shadows in the update

    private func certifiedContent() throws -> (signed: [UInt8], content: Int, offset: Int) {
        let signed = try SignatureTestHelpers.certified(.annotate)
        let document = try PdfDocument.open(signed)
        let content = try XCTUnwrap(document.pages[0].dictionary["Contents"] as? PdfReference).number
        return (signed, content, try XCTUnwrap(document.entries[content]).offset)
    }

    func test_aStreamThatClaimsMoreLengthThanItHasHidesNothing() throws {
        for length in [3, 999_999] {
            let (signed, content, _) = try certifiedContent()
            let offset = signed.count + 1
            let objects = "60 0 obj\n<</Length \(length)>>\nstream\nabc\nendstream\nendobj\n" + streamObject(content, Latin1.string(evil))

            let attacked = try Self.appendSection(signed, objects, String(format: "60 1\n%010ld 00000 n \n", offset))

            try SignatureRawKit.assertUnreadable(attacked)
        }
    }

    func test_anEntryListedOnceAndTakenBackLaterDoesNotWhitelistTheShadow() throws {
        let (signed, content, original) = try certifiedContent()
        let shadow = signed.count + 1
        let first = try Self.appendSection(signed, streamObject(content, Latin1.string(evil)), String(format: "\(content) 1\n%010ld 00000 n \n", shadow))
        let attacked = try Self.appendSection(first, "", String(format: "\(content) 1\n%010ld 00000 n \n", original))

        XCTAssertFalse(try viewerText(attacked).contains("pay 1,000,000"))
        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aHeaderWithLeadingZerosIsStillAHeader() throws {
        let (signed, content, _) = try certifiedContent()
        let body = Latin1.string(evil)
        let shadow = String(format: "%012ld", content) + " 0 obj\n<</Length \(body.unicodeScalars.count)>>\nstream\n\(body)\nendstream\nendobj\n"

        let attacked = try Self.appendSection(signed, shadow, "")

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aByteRangeWithAHugeOffsetIsRefusedWithoutThrowing() throws {
        let signed = try SignatureTestHelpers.certified(.annotate)
        let attacked = signed + TestPdf.latin("\n60 0 obj\n<</Type /Sig /ByteRange [0 9223372036854775807 100 50] /Contents <00>>>\nendobj\n")

        let reports = try SignatureKit.verify(attacked)

        XCTAssertEqual(reports[0].verdict, .changedAfterSigning)
    }

    // ---- revocation data

    private func distribution(directory: Bool) -> X509Extension {
        let name = directory
            ? DerWriter.context(4, constructed: true, X509Certificate.name("CN=Partition 7"))
            : DerWriter.ia5String(Pki.crlUrl, tag: 0x86)
        let point = DerWriter.context(0, constructed: true, DerWriter.context(0, constructed: true, name))
        return X509Extension(oid: "2.5.29.28", critical: true, value: DerWriter.sequence([point]))
    }

    private func delta() -> X509Extension {
        X509Extension(oid: "2.5.29.27", critical: true, value: DerWriter.integer(1))
    }

    private func about(_ network: FakeNetwork) throws -> RevocationState {
        let crl = try XCTUnwrap(Crl.parse(try XCTUnwrap(network.get(Pki.crlUrl))))
        return crl.about(pki.leaf, pki.intermediate).state
    }

    func test_aDeltaListThatNamesTheCertificateSaysItIsRevoked() throws {
        XCTAssertEqual(try about(SignatureObjects.network { $0.revoked = true; $0.crlExtension = self.delta() }), .revoked)
        XCTAssertEqual(try about(SignatureObjects.network { $0.crlExtension = self.delta() }), .noData)
    }

    func test_aListForAPartitionNamedByADirectoryNameIsNotComplete() throws {
        XCTAssertEqual(try about(SignatureObjects.network { $0.crlExtension = self.distribution(directory: true) }), .noData)
        XCTAssertEqual(try about(SignatureObjects.network { $0.crlExtension = self.distribution(directory: false) }), .good)
    }

    func test_anOcspResponderWhoseCertificateHadExpiredWhenItAnsweredSaysNothing() throws {
        let responder = try pki.issued("Responder", .digitalSignature, "1.3.6.1.5.5.7.3.9")
        let request = OcspResponse.buildRequest(pki.leaf, pki.intermediate)

        let currentAnswer = try XCTUnwrap(SignatureObjects.network { $0.responder = responder }.post(Pki.ocspUrl, "application/ocsp-request", request))
        let lateAnswer = try XCTUnwrap(SignatureObjects.network {
            $0.responder = responder
            $0.issued = Pki.notAfter.adding(days: 30)!
        }.post(Pki.ocspUrl, "application/ocsp-request", request))
        let current = try XCTUnwrap(OcspResponse.parse(currentAnswer))
        let late = try XCTUnwrap(OcspResponse.parse(lateAnswer))

        XCTAssertEqual(current.about(pki.leaf, pki.intermediate).state, .good)
        XCTAssertEqual(late.about(pki.leaf, pki.intermediate).state, .noData)
    }
}
#endif
