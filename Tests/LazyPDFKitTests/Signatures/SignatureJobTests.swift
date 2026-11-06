#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureJobTests.cs: the same cases. What an object is used for
// decides what may change in it: designs that name fields without using them, and objects that serve twice. The
// damaged updates of Damaged_updates_never_crash_the_verifier come from a seeded generator, not from System.Random(23).

final class SignatureJobTests: XCTestCase {
    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureRawKit.check(file) }

    private func fill(_ signed: [UInt8], _ field: Int) throws -> [UInt8] {
        try SignatureTestHelpers.edit(signed) { d in try SignatureObjects.dictionary(d, field)["V"] = SignatureObjects.text("200") }
    }

    private func form(catalog: String = "", widget: String = "") -> TestPdf {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R 7 0 R]>> \(catalog)", page: "/Contents 4 0 R /Annots [6 0 R 7 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (Send) /Rect [20 60 120 80] \(widget)>>")
        return pdf
    }

    func test_aFieldThatAButtonOnlyNamesCanBeFilled() throws {
        let actions = [
            "/A <</S /ResetForm /Fields [6 0 R]>>",
            "/A <</S /SubmitForm /F <</FS /URL /F (http://x)>> /Fields [6 0 R]>>",
            "/A <</S /Hide /T 6 0 R /H true>>",
            "/AA <</U <</S /ResetForm /Fields [6 0 R]>>>>",
        ]
        for action in actions {
            let signed = try SignatureSharedRoleTests.sign(form(widget: action), .formFill)
            XCTAssertEqual(try check(signed).verdict, .valid, action)

            let report = try check(fill(signed, 6))

            XCTAssertEqual(report.verdict, .valid, action)
            XCTAssertTrue(report.changes.changes.contains { $0.kind == .formFill && $0.object == 6 }, action)
        }
    }

    private func calculatedForm() -> TestPdf {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R] /CO [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>")
        return pdf
    }

    func test_aFieldThatTheCalculationOrderNamesCanBeFilled() throws {
        let signed = try SignatureSharedRoleTests.sign(calculatedForm(), .formFill)

        XCTAssertEqual(try check(fill(signed, 6)).verdict, .valid)
    }

    func test_aFieldThatSomethingElseUsesIsNotFilledByThatPermission() throws {
        let signed = try SignatureSharedRoleTests.sign(form(catalog: "/OpenAction <</S /Named /N 6 0 R>>"), .formFill)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let report = try check(fill(signed, 6))

        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.object == 6 })
    }

    func test_aTaggedFormIsFilledThoughTheStructureTreeNamesItsWidgetsAndPage() throws {
        let pdf = form(catalog: "/StructTreeRoot 8 0 R")
        pdf.obj(8, "<</Type /StructTreeRoot /K 9 0 R>>")
        pdf.obj(9, "<</Type /StructElem /S /Form /P 8 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 6 0 R /Pg 3 0 R>>>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let report = try check(fill(signed, 6))

        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.changes.contains { $0.kind == .formFill && $0.object == 6 })
    }

    func test_theStructureTreeItselfCannotChange() throws {
        let pdf = form(catalog: "/StructTreeRoot 8 0 R")
        pdf.obj(8, "<</Type /StructTreeRoot /K 9 0 R>>")
        pdf.obj(9, "<</Type /StructElem /S /Form /P 8 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 6 0 R /Pg 3 0 R>>>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .annotate)

        let attacked = try SignatureTestHelpers.edit(signed) { d in try SignatureObjects.dictionary(d, 9)["S"] = PdfName("Figure") }

        let report = try check(attacked)
        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.object == 9 })
    }

    func test_anAnnotationTheSignedBytesHoldUnlistedIsNotWokenByDefiningTheListThatWasMissing() throws {
        for level in [1, 3] {
            let pdf = SignatureSharedRoleTests.doc(page: "/Contents 4 0 R /Annots 7 0 R")
            pdf.obj(8, "<</Type /Annot /Subtype /Stamp /Rect [0 0 300 400] /AP <</N 9 0 R>>>>")
            pdf.stream(9, SignatureRawKit.form, "0 g")
            let before = pdf.finish()
            let after = try SignatureTestHelpers.appendRaw(before, [(7, "[8 0 R]")])

            let report = try SignatureOverlapTests.compare(before, after, level)

            XCTAssertTrue(report.notAllowed.contains { $0.object == 8 }, "\(level)")
        }
    }

    func test_aSignedRevisionWithTheCatalogInTheTrailerAcceptsNoUpdate() throws {
        let before = TestPdf.withPages(1).finish("/Root <</Type /Catalog /Pages 2 0 R>>")
        let document = try PdfDocument.open(before)
        let trailer = "<</Size \(document.nextObjectNumber) /Root <</Type /Catalog /Pages 2 0 R>> /Prev \(document.startXref)>>"
        let after = before + TestPdf.latin("xref\n0 1\n0000000000 65535 f \ntrailer\n\(trailer)\nstartxref\n\(before.count)\n%%EOF\n")

        XCTAssertTrue(try SignatureOverlapTests.compare(before, after, 1).notAllowed.contains { $0.kind == .unreadable })
    }

    func test_updatesTheEditSessionCommitsAreReadAsTheLevelAllowsAndUndoTakesThemBack() throws {
        let session = try PdfEditSession.open(SignatureTestHelpers.certified(.annotate))
        _ = try PdfAnnotationWriter(session.document).addNote(session.document.pages[0], PdfRect(250, 350, 270, 370), AnnotationInfo(author: "A", contents: "one"))
        try session.commit("Comment")
        _ = try PdfForm.read(session.document).setValue("Name", "Ada")
        try session.commit("Fill")

        let report = try SignatureKit.verify(session.current)[0]
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.changes.contains { $0.kind == .comment })
        XCTAssertTrue(report.changes.changes.contains { $0.kind == .formFill })

        try session.undo()
        try session.undo()
        XCTAssertTrue(try SignatureKit.verify(session.current)[0].changes.isEmpty)
    }

    func test_damagedUpdatesNeverCrashTheVerifier() throws {
        let signed = try SignatureTestHelpers.certified(.annotate)
        let original = try SignatureTestHelpers.edit(signed) { d in _ = try PdfForm.read(d).setValue("Name", "Ada") }
        var random = SeededRandom(23)
        for round in 0..<400 {
            var copy = original
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                copy[Int.random(in: signed.count..<copy.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
            }
            if round % 8 == 0 { copy = Array(copy[0..<Int.random(in: signed.count..<copy.count, using: &random)]) }
            do {
                for report in try SignatureKit.verify(copy) { _ = report.sentence }
            } catch is PdfReadException {
            }
        }
    }
}
#endif
