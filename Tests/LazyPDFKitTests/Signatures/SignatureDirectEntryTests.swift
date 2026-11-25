#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureDirectEntryTests.cs: the same cases. Annotations written
// inside an /Annots array, the page a bead names, the structure tree, a signature field typed by its parent and the
// bytes after the last %%EOF.

final class SignatureDirectEntryTests: XCTestCase {
    private let link = "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /A <</S /URI /URI (http://a)>>>>"

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureRawKit.check(file) }

    private func signedLink(_ indirectList: Bool = false) throws -> [UInt8] {
        let pdf = indirectList
            ? SignatureSharedRoleTests.doc(page: "/Contents 4 0 R /Annots 7 0 R")
            : SignatureSharedRoleTests.doc(page: "/Contents 4 0 R /Annots [\(link)]")
        if indirectList { pdf.obj(7, "[\(link)]") }
        return try SignatureSharedRoleTests.sign(pdf, .annotate)
    }

    private func rewritten(_ signed: [UInt8], _ indirectList: Bool, _ change: (String) -> String) throws -> [UInt8] {
        let holder = indirectList ? 7 : 3
        let text = try XCTUnwrap(PdfDocument.open(signed).get(holder)).description
        return try SignatureTestHelpers.appendRaw(signed, [(holder, change(text))])
    }

    private func prepend(_ text: String, _ marker: String, _ entry: String) -> String {
        guard let found = text.range(of: marker) else { return text }
        return String(text[..<found.upperBound]) + entry + " " + String(text[found.upperBound...])
    }

    func test_aDirectAnnotationIsJudgedByTheKeysOfAComment() throws {
        let cases: [(Bool, String, Bool)] = [
            (false, "retarget", false), (true, "retarget", false),
            (false, "script", false), (true, "script", false),
            (false, "layer", false),
            (false, "note", true), (true, "note", true),
        ]
        for (indirectList, edit, allowed) in cases {
            let signed = try signedLink(indirectList)
            let first = indirectList ? "[" : "/Annots ["

            let entry: String
            switch edit {
            case "script": entry = "<</Type /Annot /Subtype /Screen /Rect [0 0 0 0] /AA <</PO <</S /JavaScript /JS (x)>>>>>>"
            case "layer": entry = "<</Type /Annot /Subtype /Link /Rect [0 0 300 400] /A <</S /JavaScript /JS (x)>> /OC 5 0 R>>"
            default: entry = "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note) /T (A)>>"
            }
            let attacked = try rewritten(signed, indirectList) { text in
                edit == "retarget" ? text.replacingOccurrences(of: "http://a", with: "http://evil") : self.prepend(text, first, entry)
            }

            let report = try check(attacked)
            let label = "\(indirectList) \(edit)"
            XCTAssertEqual(report.verdict, allowed ? .valid : .changedAfterSigning, label)
            if !allowed { XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .comment }, label) }
        }
    }

    func test_aDirectAnnotationThatIsDroppedIsARemovedComment() throws {
        let signed = try signedLink()

        let attacked = try rewritten(signed, false) { $0.replacingOccurrences(of: self.link, with: "") }

        XCTAssertNotEqual(signed.count, attacked.count)
        XCTAssertEqual(try check(attacked).verdict, .valid)
    }

    private func signedBead() throws -> [UInt8] {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/Threads [10 0 R]", page: "/Contents 4 0 R /B [9 0 R]")
        pdf.obj(9, "<</Type /Bead /T 10 0 R /N 9 0 R /V 9 0 R /P 3 0 R /R [0 0 100 100]>>")
        pdf.obj(10, "<</Type /Thread /F 9 0 R>>")
        return try SignatureSharedRoleTests.sign(pdf, .annotate)
    }

    func test_aBeadThatNamesAPageDoesNotGiveItASecondUse() throws {
        let attacked = try SignatureTestHelpers.edit(signedBead()) { d in
            _ = try PdfAnnotationWriter(d).addNote(d.pages[0], PdfRect(250, 350, 270, 370), AnnotationInfo(author: "A", contents: "Looks fine"))
        }

        XCTAssertEqual(try check(attacked).verdict, .valid)
    }

    private func signedTagged(_ kid: String) throws -> [UInt8] {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/StructTreeRoot 11 0 R", page: "/Contents 4 0 R /Annots [7 0 R]")
        pdf.obj(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note) /T (A)>>")
        pdf.obj(11, "<</Type /StructTreeRoot /K 12 0 R>>")
        pdf.obj(12, "<</Type /StructElem /S /P /P 11 0 R /Pg 3 0 R /K \(kid)>>")
        pdf.obj(13, "<</Type /OBJR /Pg 3 0 R /Obj 7 0 R>>")
        return try SignatureSharedRoleTests.sign(pdf, .annotate)
    }

    func test_theStructureTreeNamesAnAnnotationThroughAnObjectReferenceOnly() throws {
        for (kid, verdict) in [("13 0 R", SignatureVerdict.valid), ("7 0 R", .changedAfterSigning)] as [(String, SignatureVerdict)] {
            let attacked = try SignatureTestHelpers.appendRaw(signedTagged(kid), [(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (edited) /T (A)>>")])

            XCTAssertEqual(try check(attacked).verdict, verdict, kid)
        }
    }

    func test_aSignatureFieldTypedByAParentThatDoesNotListItIsStillASignature() throws {
        let pdf = SignatureOverlapTests.formPdf(annots: "[6 0 R]", fields: "[6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /T (Sign) /Parent 7 0 R /Rect [10 10 100 40] /P 3 0 R /V 10 0 R /AP <</N 8 0 R>>>>")
        pdf.obj(7, "<</FT /Sig>>")
        pdf.stream(8, SignatureRawKit.form, "0 g")
        pdf.obj(10, "<</Type /Sig>>")
        let before = pdf.finish()

        let after = try SignatureTestHelpers.appendRaw(before, [(8, SignatureRawKit.streamBody(SignatureRawKit.evil, SignatureRawKit.form))])

        XCTAssertFalse(try SignatureOverlapTests.compare(before, after, 2).allAllowed)
    }

    func test_aTimeStampDoesNotMoveASignatureFieldThatWasOnThePage() throws {
        for placed in ["/Rect [0 0 0 0]", "/Rect [0 0 0 0] /F 2", "/Rect [0 0 300 400] /F 2"] {
            let pdf = SignatureOverlapTests.formPdf(annots: "[6 0 R]", fields: "[6 0 R]")
            pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Sig /T (Late) /Rect [0 0 300 400] /P 3 0 R /AP <</N 8 0 R>>>>")
            pdf.stream(8, SignatureRawKit.form, "BT /F1 18 Tf 40 300 Td (NOT APPROVED) Tj ET")
            let before = pdf.finish()

            let after = try SignatureTestHelpers.appendRaw(before, [
                (6, "<</Type /Annot /Subtype /Widget /FT /Sig /T (Late) \(placed) /P 3 0 R /AP <</N 8 0 R>> /V 31 0 R>>"),
                (31, SignatureOverlapTests.stampDict),
            ])

            XCTAssertFalse(try SignatureOverlapTests.compare(before, after, 1, 31).allAllowed, placed)
        }
    }

    func test_oneEndOfLineMayFollowTheSignedBytesAndNothingElse() throws {
        let cases: [(String, SignatureVerdict)] = [
            ("\n", .valid), ("\r\n", .valid), ("\r", .valid), ("\n\n", .changedAfterSigning), (" ", .changedAfterSigning),
        ]
        for (tail, verdict) in cases {
            let signed = try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(), .formFill)

            let report = try check(signed + TestPdf.latin(tail))

            XCTAssertEqual(report.verdict, verdict, "\(Array(tail.utf8))")
        }
    }

    func test_aLongRunOfWhiteSpaceAfterTheSignedBytesIsAChange() throws {
        let signed = try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(), .formFill)

        let report = try check(signed + TestPdf.latin(String(repeating: " ", count: 5000)))

        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertFalse(report.coversWholeFile)
    }
}
#endif
