#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureFieldRoleTests.cs: the same cases. Objects that an
// annotation or field points at and the document uses for something else, and what a lock covers.

final class SignatureFieldRoleTests: XCTestCase {
    private let digest = String(repeating: "A", count: 40)

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureRawKit.check(file) }

    private func assertNotAllowed(_ report: SignatureReport, _ number: Int, line: UInt = #line) {
        XCTAssertEqual(report.verdict, .changedAfterSigning, line: line)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.object == number }, line: line)
    }

    private func stamp(_ catalog: String) -> TestPdf {
        let pdf = SignatureSharedRoleTests.doc(catalog: catalog, page: "/Contents 4 0 R /Annots [7 0 R]")
        pdf.obj(7, "<</Type /Annot /Subtype /Stamp /Rect [0 0 300 400] /AP 8 0 R>>")
        pdf.obj(8, "<</N 9 0 R>>")
        pdf.stream(9, SignatureRawKit.form, "0 g")
        return pdf
    }

    func test_anAppearanceDictionaryThatValidationDataAlsoListsFollowsTheAnnotationRule() throws {
        let signed = try SignatureSharedRoleTests.sign(stamp("/DSS <</VRI <</\(digest) 8 0 R>>>>"), .noChanges)

        let attacked = try SignatureTestHelpers.appendRaw(signed, [(8, "<</N 30 0 R>>"), (30, SignatureRawKit.streamBody(SignatureRawKit.evil, SignatureRawKit.form))])

        let report = try check(attacked)
        assertNotAllowed(report, 8)
        XCTAssertFalse(report.changes.changes.contains { $0.kind == .validationData })
    }

    func test_anAppearanceDictionaryThatIsTheInformationDictionaryFollowsTheAnnotationRule() throws {
        let file = stamp("").finish("/Root 1 0 R /Info 8 0 R")
        let signed = try PdfSigner.sign(file, SignatureObjects.leafRequest { $0.certify = .formFill })

        let attacked = try SignatureTestHelpers.appendRaw(signed, [(8, "<</N 30 0 R>>"), (30, SignatureRawKit.streamBody(SignatureRawKit.evil, SignatureRawKit.form))])

        let report = try check(attacked)
        assertNotAllowed(report, 8)
    }

    func test_aParentDictionaryThatValidationDataAlsoListsCannotTakeANewValue() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm 9 0 R /DSS <</VRI <</\(digest) 6 0 R>>>>", page: "/Contents 4 0 R /Annots [7 0 R]")
        pdf.obj(6, "<</FT /Tx /V (100) /DA (0 g /F1 12 Tf)>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /T (Amount) /Parent 6 0 R /Rect [20 20 120 40]>>")
        pdf.obj(9, "<</Fields [7 0 R]>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .noChanges)

        let attacked = try SignatureTestHelpers.appendRaw(signed, [(6, "<</FT /Tx /V (1000000) /DA (0 g /F1 12 Tf)>>")])

        assertNotAllowed(try check(attacked), 6)
    }

    func test_aKidsArrayThatValidationDataAlsoListsCannotBeEmptied() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 9 0 R /DSS <</Certs 10 0 R>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [7 0 R]>>")
        pdf.stream(4, "", "BT ET")
        pdf.obj(6, "<</FT /Sig /T (Late) /Kids 10 0 R>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /Rect [10 10 100 40] /P 3 0 R /AP <</N 8 0 R>>>>")
        pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 90 30]", "0 g")
        pdf.obj(9, "<</Fields [6 0 R]>>")
        pdf.obj(10, "[7 0 R]")
        let before = pdf.finish()

        let after = try SignatureTestHelpers.appendRaw(before, [
            (10, "[]"),
            (6, "<</FT /Sig /T (Late) /Kids 10 0 R /V 30 0 R>>"),
            (30, SignatureOverlapTests.stampDict),
            (8, SignatureRawKit.streamBody("0 0 1 rg", "/Type /XObject /Subtype /Form /BBox [0 0 90 30]")),
        ])

        let report = try SignatureOverlapTests.compare(before, after, 1, 30)
        XCTAssertTrue(report.notAllowed.contains { $0.kind == .form && $0.object == 10 })
    }

    private func lockedAmount() throws -> [UInt8] {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [7 0 R]")
        pdf.obj(6, "<</FT /Tx /T (client) /Kids [7 0 R]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /V (100) /Rect [20 20 120 40]>>")
        return try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest {
            $0.certify = .formFill
            $0.lock = FieldLock(.include, ["client"])
        })
    }

    func test_aLockOnAFieldNameCoversTheFieldsBelowIt() throws {
        let attacked = try SignatureTestHelpers.edit(lockedAmount()) { d in
            try SignatureObjects.dictionary(d, 7)["V"] = SignatureObjects.text("1000000")
        }

        let report = try check(attacked)
        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .formFill && $0.object == 7 })
    }

    func test_aFieldThatASubmitActionListsCanStillBeFilled() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R 7 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R 7 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (Send) /Rect [20 60 120 80] /A <</S /SubmitForm /F <</FS /URL /F (http://x)>> /Fields [6 0 R]>>>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)

        let filled = try SignatureTestHelpers.edit(signed) { d in try SignatureObjects.dictionary(d, 6)["V"] = SignatureObjects.text("200") }

        let report = try check(filled)
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.changes.contains { $0.kind == .formFill && $0.object == 6 })
    }
}
#endif
