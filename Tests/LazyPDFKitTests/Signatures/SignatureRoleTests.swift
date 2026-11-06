#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureRoleTests.cs: the same cases. What a later revision makes a
// reader show decides the verdict, however the change is dressed up. AppendRaw is `SignatureTestHelpers.appendRaw`.

final class SignatureRoleTests: XCTestCase {
    private let pki = Pki.instance

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    private func assertChanged(_ report: SignatureReport, _ kind: SignatureChangeKind? = nil, line: UInt = #line) {
        XCTAssertEqual(report.verdict, .changedAfterSigning, line: line)
        if let kind { XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == kind }, line: line) }
    }

    // A text field whose appearance stream (7) uses the font (5) that the page text uses too.
    private func sharedFont(_ level: CertificationLevel, _ rect: PdfRect? = nil) throws -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 8 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R /Annots [6 0 R]>>")
        pdf.stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [20 20 200 50] /P 3 0 R /AP <</N 7 0 R>>>>")
        pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 180 30] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 2 8 Td (x) Tj ET")
        pdf.obj(8, "<</Fields [6 0 R]>>")
        return try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest { $0.certify = level; $0.rect = rect })
    }

    func test_aFontUsedByThePageAndByAFieldFollowsTheStricterRule() throws {
        let signed = try sharedFont(.formFill)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(signed) { d in
            try SignatureObjects.dictionary(d, 5)["BaseFont"] = PdfName("Courier")
        }

        assertChanged(try check(attacked), .pageContent)
    }

    func test_theAppearanceOfASignedSignatureFieldCannotBeReplaced() throws {
        for level in [CertificationLevel.none, .formFill, .annotate] {
            let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureObjects.leafRequest {
                $0.certify = level
                $0.rect = PdfRect(20, 20, 200, 60)
            })
            XCTAssertEqual(try check(signed).verdict, .valid, "\(level)")

            let attacked = try SignatureTestHelpers.edit(signed) { d in
                let field = try SignatureObjects.signatureField(d)
                let normal = try XCTUnwrap(d.resolve(d.dict(field.widgets[0].dictionary, "AP")?["N"]) as? PdfStream)
                normal.data = TestPdf.latin("0 g 0 0 100 30 re f")
            }

            assertChanged(try check(attacked))
        }
    }

    func test_anObjectTheUpdateCallsValidationDataIsStillJudgedByWhatItIs() throws {
        let signed = try sharedFont(.noChanges)

        let attacked = try SignatureTestHelpers.edit(signed) { d in
            d.catalog["DSS"] = SignatureObjects.entries(("X", PdfReference(7, 0)))
            try SignatureObjects.stream(d, 7).data = TestPdf.latin("BT /F1 12 Tf 2 8 Td (forged) Tj ET")
        }

        assertChanged(try check(attacked))
    }

    func test_aDanglingContentReferenceCannotBeFilledThroughTheValidationData() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents [4 0 R 9 0 R]>>")
        pdf.stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        let signed = try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest { $0.certify = .annotate })
        let evil = TestPdf.latin("BT /F1 18 Tf 40 300 Td (pay 1,000,000) Tj ET")

        let viaDss = try SignatureTestHelpers.edit(signed) { d in
            d.set(9, PdfStream(PdfDictionary(), data: evil))
            d.catalog["DSS"] = SignatureObjects.entries(("X", PdfReference(9, 0)))
        }
        let viaEdit = try SignatureTestHelpers.edit(signed) { d in
            d.set(9, PdfStream(PdfDictionary(), data: evil))
            _ = try PdfAnnotationWriter(d).addNote(d.pages[0], PdfRect(250, 350, 270, 370), AnnotationInfo(author: "A", contents: "note"))
        }

        XCTAssertTrue(SignatureKit.text(try PdfDocument.open(viaDss).pages[0].contents()).contains("pay 1,000,000"))
        assertChanged(try check(viaDss))
        assertChanged(try check(viaEdit))
    }

    private func fakeSignatureWidget(_ d: PdfDocument, _ value: PdfObject?) throws -> PdfDictionary {
        let form = PdfStream(SignatureObjects.entries(
            ("Type", PdfName("XObject")),
            ("Subtype", PdfName("Form")),
            ("BBox", SignatureObjects.numbers(0, 0, 300, 400))), data: TestPdf.latin("0 g 0 0 300 400 re f"))
        let widget = SignatureObjects.entries(
            ("Type", PdfName("Annot")),
            ("Subtype", PdfName("Widget")),
            ("FT", PdfName("Sig")),
            ("T", PdfText.toObject("Late")),
            ("Rect", PdfRect(0, 0, 300, 400).toArray()),
            ("P", d.pages[0].reference),
            ("AP", SignatureObjects.entries(("N", try d.add(form)))))
        if let value { widget["V"] = value }
        return widget
    }

    func test_aSignatureWidgetWithoutASignatureBehindItIsNotAllowed() throws {
        let cases: [(CertificationLevel, Bool)] = [(.noChanges, true), (.formFill, false), (.annotate, false), (.none, false)]
        for (level, stamp) in cases {
            let signed = level == CertificationLevel.none
                ? try PdfSigner.sign(SignatureTestHelpers.formFile(), SignatureKit.request(pki))
                : try SignatureTestHelpers.certified(level)

            let attacked = try SignatureTestHelpers.edit(signed) { d in
                let value: PdfObject?
                if stamp {
                    value = SignatureObjects.entries(("Type", PdfName("DocTimeStamp")))
                } else if level == CertificationLevel.none {
                    value = nil
                } else {
                    value = SignatureObjects.entries(("Type", PdfName("Sig")))
                }
                let widget = try d.add(self.fakeSignatureWidget(d, value))
                try XCTUnwrap(d.array(d.pages[0].dictionary, "Annots")).items.append(widget)
                try XCTUnwrap(d.array(d.dict(d.catalog, "AcroForm"), "Fields")).items.append(widget)
            }

            assertChanged(try check(attacked))
        }
    }

    func test_aRealTimeStampIsAllowedAfterACertificationWithoutChangesOnlyWhenItShowsNothing() throws {
        let certified = try SignatureTestHelpers.certified(.noChanges)
        let stamped = try PdfSigner.addDocumentTimestamp(certified, TimestampSettings(FakeNetwork(), url: "http://tsa.test/"), Pki.signing.adding(days: 1)!)
        XCTAssertEqual(try check(stamped).verdict, .valid)

        // Same width, so every offset stays; the stamp itself no longer matches, which is its own report's business.
        let at = try XCTUnwrap(SignatureObjects.lastIndex(stamped, "/Rect [0 0 0 0]"))
        XCTAssertGreaterThan(at, 0)
        var visible = stamped
        let replacement = TestPdf.latin("/Rect [0 0 9 9]")
        visible.replaceSubrange(at..<at + replacement.count, with: replacement)

        assertChanged(try check(visible), .signature)
    }

    func test_aSecondSignatureWithARealByteRangeIsStillAllowed() throws {
        let second = try PdfSigner.sign(SignatureTestHelpers.certified(.formFill),
                                        SignatureObjects.request(pki.leafEc, Pki.signing.adding(days: 1)!) { $0.rect = PdfRect(10, 10, 100, 40) })

        for report in try SignatureKit.verify(second) { XCTAssertEqual(report.verdict, .valid) }
    }

    func test_aPendingFieldFilledWithAFakeSignatureValueIsNotAllowed() throws {
        let empty = try PdfDocument.open(SignatureKit.plain())
        _ = try PdfForm.read(empty).addField(FieldSpec(.signature, "Later", 0, PdfRect(10, 10, 100, 40)))
        let prepared = try PdfSigner.sign(empty.saveIncremental(), SignatureKit.request(pki))
        XCTAssertEqual(try check(prepared).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(prepared) { d in
            let field = try XCTUnwrap(PdfForm.read(d).find("Later"))
            field.dictionary["V"] = try d.add(SignatureObjects.entries(("Type", PdfName("DocTimeStamp"))))
        }

        assertChanged(try check(attacked))
    }

    func test_aPageDictionaryWithARepeatedKeyIsNotTheSameDictionary() throws {
        let signed = try SignatureTestHelpers.certified(.annotate)
        let page = try PdfDocument.open(signed).pages[0]
        let original = page.dictionary.description

        let attacked = try SignatureTestHelpers.appendRaw(signed, [
            (50, "<</Length 22>>\nstream\nBT /F1 9 Tf (evil) Tj ET\nendstream"),
            (page.reference.number, "<</Contents 50 0 R " + String(original.dropFirst(2))),
        ])

        XCTAssertEqual(try PdfDocument.open(signed).pages[0].contents(), try PdfDocument.open(attacked).pages[0].contents())
        assertChanged(try check(attacked))
    }

    func test_anObjectFreedWhileSomethingStillPointsAtItIsReported() throws {
        for what in ["page", "widget", "stamp"] {
            let signed: [UInt8]
            if what == "stamp" {
                let withStamp = try SignatureTestHelpers.edit(SignatureTestHelpers.formFile()) { d in
                    _ = try PdfAnnotationWriter(d).addStamp(d.pages[0], PdfRect(30, 280, 270, 330), "VOID")
                }
                signed = try PdfSigner.sign(withStamp, SignatureObjects.leafRequest { $0.certify = .noChanges })
            } else {
                signed = try SignatureTestHelpers.certified(.noChanges)
            }
            let document = try PdfDocument.open(signed)
            let target: Int
            switch what {
            case "page": target = document.pages[1].reference.number
            case "widget": target = try XCTUnwrap(PdfForm.read(document).find("Name")?.reference).number
            default:
                let stamp = try XCTUnwrap(PdfAnnotations.read(document, document.pages[0]).first { $0.type == .stamp })
                target = try XCTUnwrap(stamp.reference).number
            }

            let attacked = try SignatureTestHelpers.edit(signed) { d in d.delete(target) }

            assertChanged(try check(attacked))
        }
    }
}
#endif
