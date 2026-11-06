#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureKeyTests.cs: the same cases. Keys no table names are not
// allowed: comments, read-only fields, the names a lock goes by and the information a countersigner rewrites.

final class SignatureKeyTests: XCTestCase {
    private let pki = Pki.instance

    private let note = "/Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note)"

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    private func signedNote() throws -> [UInt8] {
        let pdf = SignatureSharedRoleTests.doc(page: "/Contents 4 0 R /Annots [7 0 R]")
        pdf.obj(7, "<<\(note)>>")
        return try SignatureSharedRoleTests.sign(pdf, .annotate)
    }

    func test_aKeyThatIsNotPartOfACommentIsNotAllowedOnAnExistingOne() throws {
        let keys = [
            "/A <</S /JavaScript /JS (app.alert(1))>>",
            "/AA <</PO <</S /SetOCGState /State [/OFF 5 0 R]>>>>",
            "/Dest [3 0 R /Fit]",
            "/OC 5 0 R",
            "/StructParent 3",
            "/Rotate 180",
        ]
        for key in keys {
            let signed = try signedNote()

            let attacked = try SignatureTestHelpers.appendRaw(signed, [(7, "<<\(note) \(key)>>")])

            let report = try check(attacked)
            XCTAssertEqual(report.verdict, .changedAfterSigning, key)
            XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .comment && $0.object == 7 }, key)
        }
    }

    func test_aNewAnnotationIsAllowedForTheKeysOfACommentOnly() throws {
        let cases: [(String, Bool)] = [
            ("/Subtype /Screen /Rect [0 0 0 0] /AA <</PO <</S /SetOCGState /State [/OFF 5 0 R]>>>>", false),
            ("/Subtype /Link /Rect [0 0 300 400] /A <</S /JavaScript /JS (x)>>", false),
            ("/Subtype /FileAttachment /Rect [0 0 10 10] /FS 5 0 R", false),
            ("/Subtype /Text /Rect [250 350 270 370] /Contents (one) /T (A) /C [1 0 0] /CA 0.5 /F 4 /Name /Note", true),
        ]
        for (keys, allowed) in cases {
            let signed = try signedNote()

            let attacked = try SignatureTestHelpers.appendRaw(signed, [
                (3, try SignatureUseTests.with(signed, 3, "").replacingOccurrences(of: "/Annots [7 0 R", with: "/Annots [7 0 R 30 0 R")),
                (30, "<</Type /Annot \(keys)>>"),
            ])

            let report = try check(attacked)
            XCTAssertEqual(report.verdict, allowed ? .valid : .changedAfterSigning, keys)
            XCTAssertTrue(report.changes.changes.contains { $0.kind == .comment && $0.object == 30 && $0.allowed == allowed }, keys)
        }
    }

    func test_aCommentWhoseTextChangesIsAllowedAtLevelThree() throws {
        let attacked = try SignatureTestHelpers.appendRaw(signedNote(), [(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (edited) /C [1 0 0]>>")])

        XCTAssertEqual(try check(attacked).verdict, .valid)
    }

    private func names(_ fieldLock: FieldLock, kids: Bool) throws -> [UInt8] {
        let pdf = SignatureSharedRoleTests.doc(catalog: kids ? "/AcroForm <</Fields [6 0 R]>>" : "/AcroForm <</Fields [6 0 R 7 0 R]>>", page: "/Contents 4 0 R /Annots [7 0 R]")
        pdf.obj(6, kids ? "<</FT /Tx /T (client) /V (a) /Kids [7 0 R]>>" : "<</FT /Tx /T (client)>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /Rect [20 20 120 40]>>")
        return try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest { $0.certify = .formFill; $0.lock = fieldLock })
    }

    private func fill(_ signed: [UInt8], _ field: Int) throws -> SignatureReport {
        try check(SignatureTestHelpers.edit(signed) { d in try SignatureObjects.dictionary(d, field)["V"] = SignatureObjects.text("1000000") })
    }

    func test_aLockOnANameHoldsForAFieldListedAtTheTopThatAReaderQualifiesByItsParent() throws {
        let report = try fill(names(FieldLock(.include, ["client"]), kids: false), 7)

        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .formFill && $0.object == 7 })
    }

    func test_aLockOnAChildHoldsForTheParentValueItInherits() throws {
        let report = try fill(names(FieldLock(.include, ["client.amount"]), kids: true), 6)

        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .formFill && $0.object == 6 })
    }

    func test_aNameInAnExcludeListFreesTheFieldsBelowIt() throws {
        let report = try fill(names(FieldLock(.exclude, ["client"]), kids: true), 7)

        XCTAssertEqual(report.verdict, .valid)
    }

    func test_aNameThatIsNotInAnExcludeListStaysLocked() throws {
        let report = try fill(names(FieldLock(.exclude, ["other"]), kids: true), 7)

        XCTAssertEqual(report.verdict, .changedAfterSigning)
    }

    func test_aReadOnlyFieldIsNotFilled() throws {
        for (flags, allowed) in [("/Ff 1", false), ("/Ff 4096", true), ("", true)] {
            let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]")
            pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx \(flags) /T (Price) /V (100) /Rect [20 20 120 40]>>")
            let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)

            let report = try fill(signed, 6)

            XCTAssertEqual(report.verdict, allowed ? .valid : .changedAfterSigning, flags)
        }
    }

    func test_aFieldWhoseParentIsReadOnlyIsNotFilled() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [7 0 R]")
        pdf.obj(6, "<</FT /Tx /Ff 1 /T (client) /Kids [7 0 R]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /V (100) /Rect [20 20 120 40]>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)

        XCTAssertEqual(try fill(signed, 7).verdict, .changedAfterSigning)
    }

    func test_aCountersignerMayRewriteTheDateAndProducerOfTheInformationAndNothingElse() throws {
        let cases: [(String, Bool)] = [
            ("/ModDate (D:20261104110307Z) /Producer (Writer 2)", true),
            ("/ModDate (D:20261104110307Z) /Producer (Writer 2) /Title (pay 1,000,000)", false),
        ]
        for (keys, allowed) in cases {
            let pdf = SignatureSharedRoleTests.doc()
            pdf.obj(10, "<</ModDate (D:20261104110306Z) /Producer (Writer 1)>>")
            let signed = try PdfSigner.sign(pdf.finish("/Root 1 0 R /Info 10 0 R"), SignatureKit.request(pki))

            let attacked = try SignatureTestHelpers.appendRaw(signed, [(10, "<<\(keys)>>")])

            let report = try check(attacked)
            XCTAssertEqual(report.verdict, allowed ? .valid : .changedAfterSigning, keys)
            XCTAssertTrue(report.changes.changes.contains { $0.kind == .metadata && $0.allowed == allowed }, keys)
        }
    }
}
#endif
