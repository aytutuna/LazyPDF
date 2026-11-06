#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureOverlapTests.cs: the same cases. Objects with two jobs: a
// field, an annotation, a list or a stream that something else in the document also uses or draws.

final class SignatureOverlapTests: XCTestCase {
    private let pki = Pki.instance

    static let stampDict = "<</Type /DocTimeStamp /SubFilter /ETSI.RFC3161>>"
    private static let form = SignatureRawKit.form

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    private func assertNotAllowed(_ file: [UInt8], line: UInt = #line) throws {
        let report = try check(file)
        XCTAssertEqual(report.verdict, .changedAfterSigning, line: line)
        XCTAssertFalse(report.changes.notAllowed.isEmpty, line: line)
    }

    // A page with an empty /Annots, a form with no fields, and the update's own objects from 30 on.
    static func formPdf(catalog: String = "/AcroForm 9 0 R", annots: String = "[]", fields: String = "[]") -> TestPdf {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots \(annots)>>")
        pdf.stream(4, "", "BT ET")
        pdf.obj(9, "<</Fields \(fields)>>")
        return pdf
    }

    static func compare(_ before: [UInt8], _ after: [UInt8], _ level: Int, _ signatures: Int...) throws -> SignatureChangeReport {
        let finalDocument = try PdfDocument.open(after)
        var offsets = Set<Int>()
        for number in signatures { offsets.insert(try XCTUnwrap(finalDocument.entries[number]?.offset)) }
        return ChangeDetector.compare(try PdfDocument.open(before), finalDocument, level, offsets)
    }

    func test_aTimeStampFieldIsJudgedOnItsOwnAreaAndItsParentsWhetherOrNotTheyListIt() throws {
        for kind in ["widget", "field"] {
            let before = Self.formPdf().finish()
            let after: [UInt8]
            if kind == "widget" {
                after = try SignatureTestHelpers.appendRaw(before, [
                    (3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [32 0 R]>>"),
                    (9, "<</Fields [30 0 R]>>"),
                    (30, "<</FT /Sig /T (Late) /V 31 0 R>>"),
                    (31, Self.stampDict),
                    (32, "<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 300 400] /P 3 0 R>>"),
                ])
            } else {
                after = try SignatureTestHelpers.appendRaw(before, [
                    (9, "<</Fields [30 0 R]>>"),
                    (30, "<</FT /Sig /T (Late) /Rect [0 0 300 400] /Parent 34 0 R /V 31 0 R>>"),
                    (31, Self.stampDict),
                    (34, "<<>>"),
                ])
            }

            let report = try Self.compare(before, after, 1, 31)

            XCTAssertFalse(report.allAllowed, kind)
        }
    }

    func test_aStampOnAFieldWithNoAreaAnywhereIsStillAllowed() throws {
        let before = Self.formPdf().finish()
        let after = try SignatureTestHelpers.appendRaw(before, [
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /Rect [0 0 0 0] /V 31 0 R>>"),
            (31, Self.stampDict),
        ])

        XCTAssertTrue(try Self.compare(before, after, 1, 31).allAllowed)
    }

    func test_aNewParentThatIsNoFieldIsNotAllowedWithTheStamp() throws {
        let before = Self.formPdf().finish()
        let after = try SignatureTestHelpers.appendRaw(before, [
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /Rect [0 0 0 0] /Parent 34 0 R /V 31 0 R>>"),
            (31, Self.stampDict),
            (34, "<<>>"),
        ])

        XCTAssertFalse(try Self.compare(before, after, 1, 31).allAllowed)
    }

    func test_aDirectAnnotationsAppearanceIsACommentEvenWhenValidationDataNamesIt() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/DSS <</Certs [6 0 R]>>",
                                               page: "/Contents 4 0 R /Annots [<</Type /Annot /Subtype /Stamp /Rect [0 0 300 400] /AP <</N 6 0 R>>>>]")
        pdf.stream(6, Self.form, "0 g")
        let signed = try SignatureSharedRoleTests.sign(pdf, .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        try assertNotAllowed(SignatureTestHelpers.edit(signed) { d in try SignatureObjects.stream(d, 6).data = TestPdf.latin("1 g") })
    }

    func test_aStreamThatAnActionOrTheFormUsesIsNotValidationDataBecauseADssListsItToo() throws {
        for use in ["action", "xfa"] {
            let pdf = use == "action"
                ? SignatureSharedRoleTests.doc(catalog: "/DSS <</Certs [6 0 R]>>", page: "/Contents 4 0 R /Annots [<</Type /Annot /Subtype /Link /Rect [10 10 30 30] /A <</S /JavaScript /JS 6 0 R>>>>]")
                : SignatureSharedRoleTests.doc(catalog: "/DSS <</Certs [6 0 R]>> /AcroForm 7 0 R")
            if use == "xfa" { pdf.obj(7, "<</Fields [] /XFA 6 0 R>>") }
            pdf.stream(6, "", "app.alert\\(1\\)")
            let signed = try SignatureSharedRoleTests.sign(pdf, .noChanges)
            XCTAssertEqual(try check(signed).verdict, .valid, use)

            try assertNotAllowed(SignatureTestHelpers.edit(signed) { d in try SignatureObjects.stream(d, 6).data = TestPdf.latin("app.alert(2)") })
        }
    }

    func test_anAppearanceTheMetadataAlsoIsFollowsTheAppearanceRule() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/Metadata 6 0 R", page: "/Contents 4 0 R /Annots [7 0 R]")
        pdf.stream(6, "/Type /Metadata /Subtype /XML", "<x/>")
        pdf.obj(7, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40] /AP <</N 6 0 R>>>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)
        XCTAssertEqual(try check(signed).verdict, .valid)

        try assertNotAllowed(SignatureTestHelpers.edit(signed) { d in try SignatureObjects.stream(d, 6).data = TestPdf.latin("<y/>") })
    }

    func test_aFieldThatIsAlsoAnOptionalContentConfigurationTakesNoViewStateAsAFill() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm 8 0 R /OCProperties <</OCGs [7 0 R] /D 6 0 R>>")
        pdf.obj(6, "<</FT /Tx /T (Layer) /V (a) /BaseState /ON>>")
        pdf.obj(7, "<</Type /OCG /Name (Layer)>>")
        pdf.obj(8, "<</Fields [6 0 R]>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.appendRaw(signed, [
            (6, "<</FT /Tx /T (Layer) /V (a) /BaseState /ON /AS [<</Event /View /Category [/View] /OCGs [7 0 R]>>]>>"),
        ])

        try assertNotAllowed(attacked)
    }

    func test_anArraySharedWithAnotherJobIsNotAListOfAnnotationsOrFields() throws {
        for list in ["annots", "fields"] {
            let pdf = Self.formPdf(catalog: "/AcroForm 9 0 R /OCProperties <</OCGs [7 0 R] /D <</OFF 6 0 R>>>>",
                                   annots: list == "annots" ? "6 0 R" : "[]", fields: list == "fields" ? "6 0 R" : "[]")
            pdf.obj(6, "[]")
            pdf.obj(7, "<</Type /OCG /Name (Layer)>>")
            let before = pdf.finish()
            let after = list == "annots"
                ? try SignatureTestHelpers.appendRaw(before, [(6, "[7 0 R]")])
                : try SignatureTestHelpers.appendRaw(before, [(6, "[30 0 R]"), (30, "<</FT /Sig /T (Late) /V 31 0 R>>"), (31, Self.stampDict)])

            let report = list == "annots" ? try Self.compare(before, after, 3) : try Self.compare(before, after, 1, 31)

            XCTAssertFalse(report.allAllowed, list)
        }
    }

    func test_aStreamADirectAnnotationDrawsIsNotFreedByAnInvisibleSignatureFieldThatSharesIt() throws {
        let pdf = Self.formPdf(annots: "[<</Type /Annot /Subtype /Stamp /Rect [0 0 300 400] /AP <</N 8 0 R>>>>]", fields: "[6 0 R]")
        pdf.obj(6, "<</FT /Sig /T (Late) /AP <</N 8 0 R>>>>")
        pdf.stream(8, Self.form, "0 g")
        let before = pdf.finish()
        let after = try SignatureTestHelpers.appendRaw(before, [
            (6, "<</FT /Sig /T (Late) /AP <</N 8 0 R>> /V 31 0 R>>"),
            (8, "<<\(Self.form) /Length 8>>\nstream\n0 0 1 rg\nendstream"),
            (31, Self.stampDict),
        ])

        let report = try Self.compare(before, after, 1, 31)

        XCTAssertTrue(report.notAllowed.contains { $0.kind == .comment && $0.object == 8 })
    }

    func test_formWideDrawingSettingsAreNotAllowedWhileAFieldLockIsInForce() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>")
        let locked = try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest {
            $0.certify = .formFill
            $0.lock = FieldLock(.include, ["Amount"])
        })
        XCTAssertEqual(try check(locked).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(locked) { d in
            try XCTUnwrap(d.dict(d.catalog, "AcroForm"))["NeedAppearances"] = PdfBoolean(true)
        }

        let report = try check(attacked)
        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .formFill })
    }
}
#endif
