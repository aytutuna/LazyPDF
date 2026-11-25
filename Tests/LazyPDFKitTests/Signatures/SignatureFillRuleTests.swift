#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureFillRuleTests.cs: the same cases. What filling may touch:
// the keys a fill writes, the field a widget answers for, pushbuttons, read-only fields, the form's defaults, our own
// comments and a countersigner's metadata. The C# font source reads the installed arial.ttf; here the font is the
// synthetic font of the font program tests (A, B, space, ğ, İ), so the Turkish text is made of those letters.

final class SignatureFillRuleTests: XCTestCase {
    private let pki = Pki.instance

    private final class Arial: FontSource {
        private let data: [UInt8]

        init() throws {
            data = try SyntheticFonts.ttf()
        }

        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(data) }
    }

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    private func sign(_ pdf: TestPdf, _ fieldLock: FieldLock? = nil, _ level: CertificationLevel = .formFill) throws -> [UInt8] {
        try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest { $0.certify = level; $0.lock = fieldLock })
    }

    private func fill(_ signed: [UInt8], _ field: Int) throws -> SignatureReport {
        try check(SignatureTestHelpers.edit(signed) { d in try SignatureObjects.dictionary(d, field)["V"] = SignatureObjects.text("1000000") })
    }

    func test_aWidgetWithANameOfItsOwnIsJudgedByItsOwnNameNotItsParents() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [8 0 R]")
        pdf.obj(6, "<</FT /Tx /T (client)>>")
        pdf.obj(8, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /V (100) /Rect [20 20 120 40]>>")
        let signed = try sign(pdf, FieldLock(.include, ["client.amount"]))

        XCTAssertEqual(try fill(signed, 8).verdict, .changedAfterSigning)
    }

    func test_aWidgetWithFlagsOfItsOwnThatNoFieldListsIsNotFilled() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [8 0 R]")
        pdf.obj(6, "<</FT /Tx /T (client)>>")
        pdf.obj(8, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /Ff 1 /V (100) /Rect [20 20 120 40]>>")

        XCTAssertEqual(try fill(sign(pdf), 8).verdict, .changedAfterSigning)
    }

    func test_aKidWhoseParentIsNotTheFieldThatListsItIsJudgedByNeither() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R 7 0 R]>>", page: "/Contents 4 0 R /Annots [8 0 R]")
        pdf.obj(6, "<</FT /Tx /T (client) /Kids [8 0 R]>>")
        pdf.obj(7, "<</FT /Tx /T (other)>>")
        pdf.obj(8, "<</Type /Annot /Subtype /Widget /Parent 7 0 R /V (100) /Rect [20 20 120 40]>>")
        let signed = try sign(pdf, FieldLock(.include, ["other"]))

        XCTAssertEqual(try fill(signed, 8).verdict, .changedAfterSigning)
    }

    func test_aPushbuttonPictureIsNotAFill() throws {
        let cases: [(String, SignatureVerdict)] = [("/FT /Tx", .valid), ("/FT /Btn /Ff 65536", .changedAfterSigning)]
        for (type, verdict) in cases {
            let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]")
            pdf.obj(6, "<</Type /Annot /Subtype /Widget \(type) /T (Total) /Rect [20 20 120 40] /AP <</N 9 0 R>>>>")
            pdf.stream(9, SignatureRawKit.form, "BT /F1 18 Tf 40 300 Td (Total 100) Tj ET")
            let signed = try sign(pdf)

            let attacked = try SignatureTestHelpers.appendRaw(signed, [(9, SignatureRawKit.streamBody(SignatureRawKit.evil, SignatureRawKit.form))])

            XCTAssertEqual(try check(attacked).verdict, verdict, type)
        }
    }

    private func guarded(_ flags: String) -> TestPdf {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm 9 0 R", page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx \(flags) /T (Amount) /V (100) /Rect [20 20 120 40] /DA (/Helv 12 Tf 0 g)>>")
        pdf.obj(7, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        pdf.obj(9, "<</Fields [6 0 R] /DR <</Font <</Helv 7 0 R>>>> /DA (/Helv 12 Tf 0 g)>>")
        return pdf
    }

    func test_aReadOnlyFieldIsNotRedrawnThroughTheFormsDefaults() throws {
        let cases: [(String, String, Bool)] = [("/Ff 1", "font", false), ("/Ff 1", "redraw", false), ("", "font", true), ("", "redraw", true)]
        for (flags, how, allowed) in cases {
            let signed = try sign(guarded(flags))

            let attacked = how == "font"
                ? try SignatureTestHelpers.appendRaw(signed, [(7, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Differences [49 /nine /nine]>>>>")])
                : try SignatureTestHelpers.appendRaw(signed, [(9, try SignatureUseTests.with(signed, 9, " /NeedAppearances true"))])

            XCTAssertEqual(try check(attacked).verdict, allowed ? .valid : .changedAfterSigning, "\(flags) \(how)")
        }
    }

    func test_aLockedFormGainsAFontNoSignedFieldNamesAndNoOther() throws {
        for (name, allowed) in [("LzF1", true), ("Helv", false)] {
            let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm 9 0 R", page: "/Contents 4 0 R /Annots [6 0 R 7 0 R]")
            pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40] /DA (/Helv 12 Tf 0 g)>>")
            pdf.obj(7, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Note) /Rect [20 60 120 80] /DA (/Helv 12 Tf 0 g)>>")
            pdf.obj(9, "<</Fields [6 0 R 7 0 R]>>")
            let signed = try sign(pdf, FieldLock(.include, ["Amount"]))

            let attacked = try SignatureTestHelpers.appendRaw(signed, [
                (9, try SignatureUseTests.with(signed, 9, " /DR <</Font <</\(name) 30 0 R>>>>")),
                (30, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"),
            ])

            XCTAssertEqual(try check(attacked).verdict, allowed ? .valid : .changedAfterSigning, name)
        }
    }

    private func library(_ setup: (PdfForm) throws -> Void, _ fieldLock: FieldLock? = nil) throws -> [UInt8] {
        let document = try PdfDocument.open(SignatureKit.plain())
        try setup(PdfForm.read(document))
        return try PdfSigner.sign(document.saveIncremental(), SignatureObjects.leafRequest { $0.certify = .formFill; $0.lock = fieldLock })
    }

    private func addFields(_ form: PdfForm) throws {
        _ = try form.addField(FieldSpec(.text, "Name", 0, PdfRect(40, 200, 240, 224)))
        var pick = FieldSpec(.listBox, "Pick", 0, PdfRect(40, 100, 240, 160))
        pick.options = (0..<20).map { FieldOption("o\($0)") }
        _ = try form.addField(pick)
        _ = try form.addField(FieldSpec(.text, "Rich", 0, PdfRect(40, 60, 240, 84)))
    }

    func test_lettersTheFormsFontLacksAreFilledFromANewFont() throws {
        let signed = try library(addFields)

        let filled = try SignatureTestHelpers.edit(signed) { d in _ = try PdfForm.read(d, Arial()).setValue("Name", "AİB ğA") }

        XCTAssertEqual(try check(filled).verdict, .valid)
    }

    func test_aListBoxScrolledByAFillIsFilled() throws {
        let signed = try library(addFields)

        let filled = try SignatureTestHelpers.edit(signed) { d in _ = try PdfForm.read(d).setValue("Pick", "o15") }

        XCTAssertEqual(try check(filled).verdict, .valid)
    }

    func test_aRichTextValueIsReplacedByAFill() throws {
        let signed = try library { form in
            try self.addFields(form)
            try XCTUnwrap(form.find("Rich")).dictionary["RV"] = PdfText.toObject("<body><p>old</p></body>")
        }

        let filled = try SignatureTestHelpers.edit(signed) { d in _ = try PdfForm.read(d).setValue("Rich", "new") }

        XCTAssertEqual(try check(filled).verdict, .valid)
    }

    func test_aFillOfOneFieldDoesNotNeedTheFormToBeUnlocked() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm 9 0 R", page: "/Contents 4 0 R /Annots [6 0 R 7 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Note) /Rect [20 60 120 80]>>")
        pdf.obj(9, "<</Fields [6 0 R 7 0 R]>>")
        let signed = try sign(pdf, FieldLock(.include, ["Amount"]))

        let filled = try SignatureTestHelpers.edit(signed) { d in _ = try PdfForm.read(d).setValue("Note", "Ada") }

        XCTAssertEqual(try check(filled).verdict, .valid)
    }

    func test_marksOurOwnWriterMakesAreComments() throws {
        for kind in ["caret", "redact"] {
            let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureObjects.leafRequest { $0.certify = .annotate })

            let marked = try SignatureTestHelpers.edit(signed) { d in
                let writer = PdfAnnotationWriter(d)
                if kind == "caret" {
                    _ = try writer.addCaret(d.pages[0], PdfRect(100, 100, 110, 112), info: AnnotationInfo(author: "A", contents: "insert"))
                } else {
                    _ = try writer.addRedact(d.pages[0], [MarkupQuad.fromRect(PdfRect(100, 600, 200, 614))], info: AnnotationInfo(author: "A"),
                                             fill: [0, 0, 0], overlayText: "REDACTED")
                }
            }

            XCTAssertEqual(try check(marked).verdict, .valid, kind)
        }
    }

    private func xmp(_ tool: String, _ date: String, _ producer: String) -> String {
        "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" xmp:CreatorTool=\"\(tool)\" xmp:ModifyDate=\"\(date)\" rdf:about=\"\" pdf:Producer=\"\(producer)\"/>"
            + "</rdf:RDF></x:xmpmeta><?xpacket end=\"r\"?>"
    }

    func test_aPacketThatOnlyRestampsItsDatesAndProducerPassesBelowLevelTwo() throws {
        let cases: [(String, String, String, SignatureVerdict)] = [
            ("Word", "2026-11-04T12:18:19-05:00", "Writer 2", .valid),
            ("Other", "2026-11-04T12:18:19-05:00", "Writer 1", .changedAfterSigning),
        ]
        for (tool, date, producer, verdict) in cases {
            let pdf = SignatureSharedRoleTests.doc(catalog: "/Metadata 6 0 R")
            pdf.stream(6, "/Type /Metadata /Subtype /XML", xmp("Word", "2026-11-04T12:18:17-05:00", "Writer 1"))
            let signed = try PdfSigner.sign(pdf.finish(), SignatureKit.request(pki))

            let attacked = try SignatureTestHelpers.appendRaw(signed, [(6, SignatureRawKit.streamBody(xmp(tool, date, producer), "/Type /Metadata /Subtype /XML"))])

            XCTAssertEqual(try check(attacked).verdict, verdict, tool)
        }
    }
}
#endif
