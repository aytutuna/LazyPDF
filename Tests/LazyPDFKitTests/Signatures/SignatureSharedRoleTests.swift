#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureSharedRoleTests.cs: the same cases, and the helpers of
// SignatureChangeTests (edit, certified) and SignatureRoleTests (appendRaw) that the other signature tests use.
// Objects that hold two jobs, entries the signed revision could not read and list entries that look the same but are not.

enum SignatureTestHelpers {
    static func edit(_ file: [UInt8], _ change: (PdfDocument) throws -> Void) throws -> [UInt8] {
        let document = try PdfDocument.open(file)
        try change(document)
        return try document.saveIncremental()
    }

    /// Two pages and two text fields, Name and Date.
    static func formFile() throws -> [UInt8] {
        let document = try PdfDocument.open(SignatureKit.plain())
        let form = PdfForm.read(document)
        _ = try form.addField(FieldSpec(.text, "Name", 0, PdfRect(40, 200, 240, 224)))
        _ = try form.addField(FieldSpec(.text, "Date", 0, PdfRect(40, 160, 240, 184)))
        return try document.saveIncremental()
    }

    static func certified(_ level: CertificationLevel, _ fieldLock: FieldLock? = nil) throws -> [UInt8] {
        var request = SignatureKit.request(Pki.instance)
        request.certify = level
        request.lock = fieldLock
        return try PdfSigner.sign(formFile(), request)
    }

    static func first(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    static func appendRaw(_ file: [UInt8], _ objects: [(number: Int, body: String)]) throws -> [UInt8] {
        let document = try PdfDocument.open(file)
        var text = "\n"
        var offsets: [(Int, Int)] = []
        for (number, body) in objects {
            offsets.append((number, file.count + text.unicodeScalars.count))
            text += "\(number) 0 obj\n\(body)\nendobj\n"
        }
        let xref = file.count + text.unicodeScalars.count
        text += "xref\n"
        for (number, offset) in offsets.sorted(by: { $0.0 < $1.0 }) { text += "\(number) 1\n" + String(format: "%010ld 00000 n \n", offset) }
        let highest = objects.map { $0.number }.max() ?? 0
        text += "trailer\n<</Size \(max(document.nextObjectNumber, highest + 1)) \(SignatureRawKit.kept(document)) /Prev \(document.startXref)>>\nstartxref\n\(xref)\n%%EOF\n"
        return file + TestPdf.latin(text)
    }
}

final class SignatureSharedRoleTests: XCTestCase {
    private let pki = Pki.instance
    private let evil = "BT /F1 18 Tf 40 300 Td (pay 1,000,000) Tj ET"

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureKit.verify(file)[0] }

    static func doc(catalog: String = "", page: String = "/Contents 4 0 R") -> TestPdf {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> \(page)>>")
        pdf.stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET")
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        return pdf
    }

    static func sign(_ pdf: TestPdf, _ level: CertificationLevel) throws -> [UInt8] {
        var request = SignatureKit.request(Pki.instance)
        request.certify = level
        return try PdfSigner.sign(pdf.finish(), request)
    }

    private func assertNotAllowed(_ report: SignatureReport, _ kind: SignatureChangeKind? = nil, line: UInt = #line) {
        XCTAssertEqual(report.verdict, .changedAfterSigning, line: line)
        if let kind { XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == kind }, line: line) }
    }

    func test_anObjectTheSignedRevisionCouldNotReadShowsTheUpdatesBytesAsNew() throws {
        let pdf = Self.doc(page: "/Contents [4 0 R 9 0 R]")
        pdf.obj(9, "<</Length \(evil.count) /X (")
        let signed = try Self.sign(pdf, .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try appendSection(signed, ")>>\nstream\n\(evil)\nendstream\nendobj\n", "")

        XCTAssertTrue(SignatureKit.text(try PdfDocument.open(attacked).pages[0].contents()).contains("pay 1,000,000"))
        assertNotAllowed(try check(attacked), .unreadable)
    }

    func test_anObjectThatValidationDataOrACommentSharesWithAnotherJobKeepsTheStricterOne() throws {
        for role in ["validation", "annotation", "appearance"] {
            let pdf: TestPdf
            switch role {
            case "validation": pdf = Self.doc(catalog: "/OpenAction 7 0 R /DSS <</Certs [7 0 R]>>")
            case "annotation": pdf = Self.doc(catalog: "/OpenAction 6 0 R", page: "/Contents 4 0 R /Annots [6 0 R]")
            default: pdf = Self.doc(catalog: "/OpenAction 8 0 R", page: "/Contents 4 0 R /Annots [6 0 R]")
            }
            pdf.stream(7, "/S /JavaScript /JS (app.alert\\(1\\))", "x")
            let appearance = role == "appearance" ? "/AP <</N 8 0 R>>" : ""
            if role != "validation" {
                pdf.obj(6, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (note) /S /JavaScript /JS (app.alert\\(1\\)) \(appearance)>>")
            }
            if role == "appearance" { pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 20 20] /S /JavaScript /JS (app.alert\\(1\\))", "x") }
            let signed = try Self.sign(pdf, .annotate)
            XCTAssertEqual(try check(signed).verdict, .valid, role)

            let attacked = try SignatureTestHelpers.edit(signed) { d in
                switch role {
                case "validation": (d.get(7) as? PdfStream)?.data = TestPdf.latin("y")
                case "annotation": (d.get(6) as? PdfDictionary)?["JS"] = PdfString(bytes: TestPdf.latin("app.alert(2)"), isHex: false)
                default: (d.get(8) as? PdfStream)?.data = TestPdf.latin("y")
                }
            }

            assertNotAllowed(try check(attacked))
        }
    }

    func test_validationDataNamedByAnObjectOfAnotherKindFreesNothing() throws {
        let pdf = Self.doc(catalog: "/DSS <</Certs 6 0 R>> /OCProperties <</D 6 0 R /OCGs []>>")
        pdf.obj(6, "<</Order [] /BaseState /ON>>")
        let signed = try Self.sign(pdf, .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(signed) { d in (d.get(6) as? PdfDictionary)?["BaseState"] = PdfName("OFF") }

        assertNotAllowed(try check(attacked))
    }

    func test_aCommentThatNothingElseUsesIsStillACommentAtLevelThree() throws {
        let pdf = Self.doc(page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (note)>>")
        let signed = try Self.sign(pdf, .annotate)

        let edited = try SignatureTestHelpers.edit(signed) { d in
            (d.get(6) as? PdfDictionary)?["Contents"] = PdfString(bytes: TestPdf.latin("changed"), isHex: false)
        }

        let report = try check(edited)
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.changes.contains { $0.kind == .comment && $0.object == 6 })
    }

    func test_anArrayThatIsBothAnnotationsAndPageContentFollowsTheContentRule() throws {
        let pdf = Self.doc(page: "/Contents 6 0 R /Annots 6 0 R")
        pdf.obj(6, "[4 0 R]")
        let signed = try Self.sign(pdf, .annotate)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.appendRaw(signed, [
            (30, "<</Length \(evil.count)>>\nstream\n\(evil)\nendstream"),
            (6, "[4 0 R 30 0 R]"),
        ])

        XCTAssertTrue(SignatureKit.text(try PdfDocument.open(attacked).pages[0].contents()).contains("pay 1,000,000"))
        assertNotAllowed(try check(attacked), .pageContent)
    }

    // The field of a widget kept apart has no /Rect of its own; the stamp is judged on every widget under it.
    private func stampOnField(_ widgetRect: String, rewriteAppearance: Bool) throws -> SignatureChangeReport {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 9 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [7 0 R]>>")
        pdf.stream(4, "", "BT ET")
        pdf.obj(6, "<</FT /Sig /T (Late) /Kids [7 0 R]>>")
        pdf.obj(7, "<</Type /Annot /Subtype /Widget /Parent 6 0 R \(widgetRect) /P 3 0 R /AP <</N 8 0 R>>>>")
        pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 90 30]", "0 g")
        pdf.obj(9, "<</Fields [6 0 R]>>")
        let before = pdf.finish()

        var update: [(number: Int, body: String)] = [(6, "<</FT /Sig /T (Late) /Kids [7 0 R] /V 30 0 R>>"), (30, "<</Type /DocTimeStamp /SubFilter /ETSI.RFC3161>>")]
        if rewriteAppearance { update.append((8, "<</Type /XObject /Subtype /Form /BBox [0 0 90 30] /Length 8>>\nstream\n0 0 1 rg\nendstream")) }
        let after = try SignatureTestHelpers.appendRaw(before, update)

        let final = try PdfDocument.open(after)
        let offset = try XCTUnwrap(final.entries[30]).offset
        return ChangeDetector.compare(try PdfDocument.open(before), final, 1, [offset])
    }

    func test_aTimeStampInAFieldWhoseWidgetShowsSomethingIsNotAllowedAfterACertification() throws {
        XCTAssertFalse(try stampOnField("/Rect [10 10 100 40]", rewriteAppearance: true).allAllowed)
    }

    func test_aTimeStampInAFieldWhoseWidgetShowsNothingIsAllowedAfterACertification() throws {
        XCTAssertTrue(try stampOnField("/Rect [0 0 0 0]", rewriteAppearance: false).allAllowed)
    }

    func test_swappingADrawnAnnotationWithAListedOneChangesTheStacking() throws {
        let pdf = Self.doc(page: "/Contents 4 0 R /Annots [<</Subtype /Square /Rect [0 0 300 400]>> 6 0 R 8 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40]>>")
        pdf.obj(8, "<</Type /Annot /Subtype /Text /Rect [100 10 120 30]>>")
        let signed = try Self.sign(pdf, .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(signed) { d in
            guard let annots = d.array(d.pages[0].dictionary, "Annots") else { return }
            annots.items.swapAt(0, 1)
        }

        assertNotAllowed(try check(attacked), .comment)
    }

    func test_aReferenceWithAnotherGenerationIsNotTheSameAnnotation() throws {
        let pdf = Self.doc(page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40] /Contents (VOID)>>")
        let signed = try Self.sign(pdf, .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.edit(signed) { d in
            d.array(d.pages[0].dictionary, "Annots")?.items[0] = PdfReference(6, 3)
        }

        assertNotAllowed(try check(attacked), .comment)
    }

    func test_aReferenceWithAnotherGenerationIsNotTheSameField() throws {
        let signed = try SignatureTestHelpers.certified(.noChanges)

        let attacked = try SignatureTestHelpers.edit(signed) { d in
            guard let fields = d.array(d.dict(d.catalog, "AcroForm"), "Fields"), let first = fields.items[0] as? PdfReference else { return }
            fields.items[0] = PdfReference(first.number, 4)
        }

        assertNotAllowed(try check(attacked), .form)
    }
}

/// SignatureForgeryTests.AppendSection: an update of `objects` and a table of `entries`.
func appendSection(_ signed: [UInt8], _ objects: String, _ entries: String) throws -> [UInt8] {
    let document = try PdfDocument.open(signed)
    var text = "\n" + objects
    let xref = signed.count + text.unicodeScalars.count
    text += "xref\n\(entries)trailer\n<</Size \(document.nextObjectNumber)\(SignatureRawKit.kept(document)) /Prev \(document.startXref)>>\nstartxref\n\(xref)\n%%EOF\n"
    return signed + TestPdf.latin(text)
}
#endif
