#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureUseTests.cs: the same cases. What a name, a back link or a
// destination stands for in the walk: a use, or only a way to name.

final class SignatureUseTests: XCTestCase {
    private let pki = Pki.instance

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    private func assertChanged(_ file: [UInt8], _ number: Int, line: UInt = #line) throws {
        let report = try check(file)
        XCTAssertEqual(report.verdict, .changedAfterSigning, line: line)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.object == number }, line: line)
    }

    // The job kinds of an object, once each, in the order of the enum, by the names the C# enum has.
    private func kinds(_ file: [UInt8], _ number: Int) throws -> String {
        let order: [JobKind] = [.trailer, .plain, .content, .structure, .link, .catalog, .pageTree, .page, .annotList, .comment, .form,
                                .fieldList, .field, .appearance, .value, .info, .dss, .action, .defaults]
        let found = Set(Jobs(try PdfDocument.open(file)).of(number).map { $0.kind })
        return order.filter { found.contains($0) }.map { "\($0)".prefix(1).uppercased() + "\($0)".dropFirst() }.joined(separator: " ")
    }

    func test_aParentThatDoesNotListItsChildBackIsAUseOfIt() throws {
        let pdf = SignatureSharedRoleTests.doc(page: "/Contents 4 0 R /Annots [7 0 R]")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 7 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R /Annots [7 0 R]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note)>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .annotate)

        XCTAssertEqual(try kinds(signed, 7), "Plain Comment")
        let attacked = try SignatureTestHelpers.appendRaw(signed, [(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note) /Rotate 180>>")])
        try assertChanged(attacked, 7)
    }

    func test_aParentThatListsItsChildAndAPopupThatNamesItsAnnotationAreNotUses() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [7 0 R 8 0 R 9 0 R]")
        pdf.obj(6, "<</FT /Tx /T (client) /Kids [9 0 R]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note) /Popup 8 0 R>>")
        pdf.obj(8, "<</Type /Annot /Subtype /Popup /Rect [250 300 300 340] /Parent 7 0 R>>")
        pdf.obj(9, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /V (100) /Rect [20 20 120 40]>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .annotate)

        XCTAssertEqual(try kinds(signed, 7), "Comment")
        XCTAssertEqual(try kinds(signed, 8), "Comment")
        XCTAssertEqual(try kinds(signed, 6), "Field")
        let edited = try SignatureTestHelpers.appendRaw(signed, [(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (edited) /Popup 8 0 R>>")])
        XCTAssertEqual(try check(edited).verdict, .valid)
    }

    func test_aStampFieldASignedPageNamesAsItsParentIsNotAllowedAfterACertification() throws {
        let before = SignatureOverlapTests.formPdf(annots: "[]").finish()
        let named = try SignatureTestHelpers.appendRaw(before, [(3, "<</Type /Page /Parent 30 0 R /Contents 4 0 R /Annots []>>")])
        let after = try SignatureTestHelpers.appendRaw(named, [
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /Rotate 180 /Resources <<>> /V 31 0 R>>"),
            (31, SignatureOverlapTests.stampDict),
        ])

        let report = try SignatureOverlapTests.compare(named, after, 1, 31)

        XCTAssertFalse(report.allAllowed)
        XCTAssertTrue(report.notAllowed.contains { $0.object == 30 })
    }

    func test_aDictionaryThatCallsItselfAHideOrResetActionNamesNothingUnlessItIsOne() throws {
        for (where_, keys) in [("a text annotation", "/Subtype /Text /S /Hide /T 8 0 R"), ("the form", "")] {
            let form = where_ == "the form"
            let pdf = SignatureSharedRoleTests.doc(
                catalog: form ? "/AcroForm <</Fields 8 0 R /S /ResetForm>> /DSS <</Certs [8 0 R]>>" : "/DSS <</Certs [8 0 R]>>",
                page: form ? "/Contents 4 0 R" : "/Contents 4 0 R /Annots [7 0 R]")
            if !form { pdf.obj(7, "<</Type /Annot \(keys) /Rect [250 350 270 370]>>") }
            pdf.obj(8, form ? "[6 0 R]" : "(Alice, Legal)")
            if form { pdf.obj(6, "<</FT /Tx /T (Amount) /V (100)>>") }
            let signed = try SignatureSharedRoleTests.sign(pdf, .noChanges)
            XCTAssertEqual(try check(signed).verdict, .valid, where_)

            let attacked = try SignatureTestHelpers.appendRaw(signed, [(8, form ? "[]" : "(Mallory)")])

            try assertChanged(attacked, 8)
        }
    }

    func test_aPageADestinationNamesCanTakeTheWidgetOfASignature() throws {
        for level in [CertificationLevel.none, .formFill] {
            let pdf = SignatureSharedRoleTests.doc(catalog: "/OpenAction [3 0 R /Fit] /Outlines 20 0 R")
            pdf.obj(20, "<</Type /Outlines /First 21 0 R /Last 21 0 R /Count 1>>")
            pdf.obj(21, "<</Title (One) /Parent 20 0 R /Dest [3 0 R /XYZ 0 0 0]>>")
            let first = try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest { $0.certify = level })

            let both = try SignatureObjects.second(first, fieldName: "Second")

            for report in try SignatureKit.verify(both) { XCTAssertEqual(report.verdict, .valid, "\(level)") }
        }
    }

    func test_aPageADestinationNamesCanTakeANote() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/OpenAction [3 0 R /Fit]")
        let signed = try SignatureSharedRoleTests.sign(pdf, .annotate)

        let noted = try SignatureTestHelpers.edit(signed) { d in
            _ = try PdfAnnotationWriter(d).addNote(d.pages[0], PdfRect(250, 350, 270, 370), AnnotationInfo(author: "A", contents: "one"))
        }

        let report = try check(noted)
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.changes.contains { $0.kind == .comment })
    }

    func test_aPageSomethingElseUsesIsStillAPageWithASecondJob() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/OpenAction <</S /Named /N 3 0 R>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .annotate)

        XCTAssertTrue(try kinds(signed, 3).contains("Plain"))
    }

    func test_aSignatureInAFieldThatHasNoWidgetGivesItOneWithoutTheFirstReadingAsChanged() throws {
        for level in [CertificationLevel.none, .formFill] {
            let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R 7 0 R]>>")
            pdf.obj(6, "<</FT /Sig /T (A)>>")
            pdf.obj(7, "<</FT /Sig /T (B)>>")
            let first = try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest { $0.fieldName = "A"; $0.certify = level })

            let both = try SignatureObjects.second(first, fieldName: "B")

            for report in try SignatureKit.verify(both) { XCTAssertEqual(report.verdict, .valid, "\(level)") }
        }
    }

    func test_aFontThatTheFormsDefaultsGainIsTheOneTheNewAppearanceDrawsWith() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /DA (/Helv 12 Tf 0 g) /V (100) /Rect [20 20 120 40]>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)

        let filled = try SignatureTestHelpers.edit(signed) { d in _ = try PdfForm.read(d).setValue("Amount", "200") }

        XCTAssertTrue(TestPdf.text(Array(filled[signed.count...])).contains("DR"))
        let report = try check(filled)
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.changes.contains { $0.kind == .formFill && $0.object == 6 })
    }

    func test_aFontOfTheFormsDefaultsCannotBeChangedWhenSomethingSignedDrawsWithIt() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R] /DR <</Font <</Helv 5 0 R>>>>>>", page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)

        XCTAssertEqual(try kinds(signed, 5), "Content Defaults")
        try assertChanged(SignatureTestHelpers.appendRaw(signed, [(5, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>")]), 5)
    }

    // An object as the signed file has it with more keys at its end.
    static func with(_ file: [UInt8], _ number: Int, _ keys: String) throws -> String {
        let text = try XCTUnwrap(PdfDocument.open(file).get(number)).description
        let end = try XCTUnwrap(text.range(of: ">>", options: .backwards))
        return String(text[..<end.lowerBound]) + keys + ">>"
    }

    func test_aTimeStampOfAValidationEntryIsValidationData() throws {
        let signed = try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(), .none)
        let key = String(repeating: "a", count: 40)
        let after = try SignatureTestHelpers.appendRaw(signed, [
            (1, try Self.with(signed, 1, " /DSS 30 0 R")),
            (30, "<</VRI 31 0 R>>"),
            (31, "<</\(key) 33 0 R>>"),
            (33, "<</TS 32 0 R>>"),
            (32, SignatureRawKit.streamBody("token")),
        ])

        let report = try check(after)
        XCTAssertEqual(report.verdict, .valid)
        for change in report.changes.changes { XCTAssertEqual(change.kind, .validationData) }
    }
}
#endif
