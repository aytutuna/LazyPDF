#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureUpdateBytesTests.cs: the same cases. What an update's bytes
// and tables say beyond the objects they define: the trailer, the page list, entries that need repair, odd numbers
// and unlisted objects.

final class SignatureUpdateBytesTests: XCTestCase {
    private let evil = SignatureRawKit.evil
    private let openAction = "<</Type /Catalog /Pages 2 0 R /OpenAction <</S /JavaScript /JS (x)>>>>"

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureRawKit.check(file) }

    private func length(_ text: String) -> Int { text.unicodeScalars.count }

    private func offset(_ value: Int) -> String { String(format: "%010ld", value) }

    private func assertNotAllowed(_ file: [UInt8], line: UInt = #line) throws {
        let report = try check(file)
        XCTAssertEqual(report.verdict, .changedAfterSigning, line: line)
    }

    // An update with the given trailer entries in place of /Root.
    private func appendTrailer(_ file: [UInt8], _ trailer: String, _ objects: [(number: Int, body: String)] = []) throws -> [UInt8] {
        let document = try PdfDocument.open(file)
        var text = "\n"
        var offsets: [(number: Int, offset: Int)] = []
        for (number, body) in objects {
            offsets.append((number, file.count + length(text)))
            text += "\(number) 0 obj\n\(body)\nendobj\n"
        }
        let xref = file.count + length(text)
        text += "xref\n0 1\n0000000000 65535 f \n"
        for (number, at) in offsets.sorted(by: { $0.number < $1.number }) { text += "\(number) 1\n\(offset(at)) 00000 n \n" }
        let size = max(document.nextObjectNumber, offsets.map { $0.number + 1 }.max() ?? 0)
        text += "trailer\n<</Size \(size) \(trailer)\(SignatureRawKit.identity(document)) /Prev \(document.startXref)>>\nstartxref\n\(xref)\n%%EOF\n"
        return file + TestPdf.latin(text)
    }

    private func streamBody(_ data: String) -> String { "<</Length \(length(data))>>\nstream\n\(data)\nendstream" }

    // ---- the trailer

    func test_aFinalTrailerThatNamesAnotherCatalogIsAChangeHoweverItIsWritten() throws {
        let cases: [(String, Bool)] = [
            ("/Root <</Type /Catalog /Pages 2 0 R /OpenAction <</S /JavaScript /JS (x)>>>>", true),
            ("/Root 1 3 R", false),
            ("/Root 20 0 R /Root 1 0 R", false),
        ]
        for (root, direct) in cases {
            let before = TestPdf.withPages(1).finish(direct ? "/Root <</Type /Catalog /Pages 2 0 R>>" : "/Root 1 0 R")

            let after = try appendTrailer(before, root, [(20, openAction)])

            XCTAssertTrue(try SignatureOverlapTests.compare(before, after, 1).notAllowed.contains { $0.kind == .unreadable }, root)
        }
    }

    func test_anInformationDictionaryNamedWithAnotherGenerationIsAChange() throws {
        let pdf = TestPdf.withPages(1)
        pdf.obj(5, "<</Title (x)>>")
        let before = pdf.finish("/Root 1 0 R /Info 5 0 R")

        let after = try appendTrailer(before, "/Root 1 0 R /Info 5 3 R")

        XCTAssertFalse(try SignatureOverlapTests.compare(before, after, 1).allAllowed)
    }

    // ---- the page list

    func test_aPageObjectTheRepairScanAddsToTheDocumentIsAChange() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>")
        pdf.stream(4, "", "BT ET")
        let before = pdf.finish()
        let after = try SignatureTestHelpers.appendRaw(before, [(30, "<</Type /Page /Parent 2 0 R /Contents 31 0 R>>"), (31, streamBody(evil))])

        XCTAssertEqual(try PdfDocument.open(after).pages.count, 2)
        XCTAssertTrue(try SignatureOverlapTests.compare(before, after, 1).notAllowed.contains { $0.kind == .unreadable })
    }

    // ---- bytes the update adds to the signed ones

    // The signed bytes end inside a comment that looks like the file's last startxref line, with an object open above it.
    private func openObject() -> (bytes: [UInt8], xref: Int) {
        let pdf = TestPdf()
        var starts = [Int](repeating: 0, count: 5)
        starts[1] = pdf.position
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        starts[2] = pdf.position
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>")
        starts[3] = pdf.position
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents [4 0 R 9 0 R]>>")
        starts[4] = pdf.position
        pdf.stream(4, "", "BT ET")
        let xref = pdf.position
        let head = "xref\n0 10\n0000000000 65535 f \n"
            + (1...4).map { "\(offset(starts[$0])) 00000 n \n" }.joined()
            + String(repeating: "0000000000 00000 f \n", count: 4)
        let trailer = "trailer\n<</Size 10 /Root 1 0 R>>\n"
        let open = xref + length(head) + 20 + length(trailer)
        pdf.write("\(head)\(offset(open)) 00000 n \n\(trailer)9 0 obj\n<</Length \(length(evil))>>\n%startxref \(xref)\n%%EOF\n")
        return (pdf.finishWithoutXref(), xref)
    }

    func test_aDictionaryTheSignedBytesLeaveOpenCanBecomeAStream() throws {
        let (before, xref) = openObject()
        let closing = "stream\n\(evil)\nendstream\nendobj\n"
        let next = before.count + length(closing)
        let after = before + TestPdf.latin("\(closing)xref\n0 1\n0000000000 65535 f \ntrailer\n<</Size 10 /Root 1 0 R /Prev \(xref)>>\nstartxref\n\(next)\n%%EOF\n")

        XCTAssertTrue(SignatureKit.text(try PdfDocument.open(after).pages[0].contents()).contains(evil))
        let report = try SignatureOverlapTests.compare(before, after, 1)

        XCTAssertTrue(report.notAllowed.contains { $0.kind == .unreadable })
    }

    func test_anEntryTheUpdateListsWhereTheObjectIsNotIsAChange() throws {
        let pdf = SignatureSharedRoleTests.doc(page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40] /Contents (VOID)>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let comment = signed.count + 1
        let attacked = try SignatureForgeryTests.appendSection(signed, "% nothing here\n", "6 1\n\(offset(comment)) 00000 n \n")

        try assertNotAllowed(attacked)
    }

    // ---- numbers a reader may take differently

    func test_aReferenceWrittenWithASignInsideTheNumberIsAChange() throws {
        let signed = try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(), .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)
        let page = try XCTUnwrap(PdfDocument.open(signed).get(3)).description.replacingOccurrences(of: "/Contents 4 0 R", with: "/Contents 4-9 0 R")
        XCTAssertTrue(page.contains("4-9"))

        let attacked = try SignatureTestHelpers.appendRaw(signed, [(3, page), (49, streamBody(evil))])

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aStampWhoseAreaIsWrittenWithSignsInsideTheNumbersIsNotEmpty() throws {
        let before = SignatureOverlapTests.formPdf().finish()
        let after = try SignatureTestHelpers.appendRaw(before, [
            (3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [32 0 R]>>"),
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /V 31 0 R>>"),
            (31, SignatureOverlapTests.stampDict),
            (32, "<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 0-300 0-400] /P 3 0 R>>"),
        ])

        XCTAssertFalse(try SignatureOverlapTests.compare(before, after, 1, 31).allAllowed)
    }

    // ---- references nested deeply

    func test_aDanglingReferenceAtTheEndOfADeepChainIsClaimedByANewObject() throws {
        var chain = "99 0 R"
        for _ in 0..<40 { chain = "<</S /Named /N /NextPage /Next \(chain)>>" }
        let signed = try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(catalog: "/OpenAction \(chain)"), .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.appendRaw(signed, [(99, "<</S /JavaScript /JS (app.alert\\(1\\))>>")])

        try assertNotAllowed(attacked)
    }

    // ---- objects after the signed revision that no table lists

    func test_anObjectHeaderWithNoGapBeforeObjIsFoundLikeAnyOther() throws {
        let signed = try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(), .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureForgeryTests.appendSection(signed, "4 0obj\n\(streamBody(evil))\nendobj\n", "")

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_anUnlistedObjectForANumberTheSignedRevisionOnlyPointsAtIsFound() throws {
        let signed = try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(page: "/Contents [4 0 R 99 0 R]"), .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureForgeryTests.appendSection(signed, "99 0 obj\n\(streamBody(evil))\nendobj\n", "")

        try SignatureRawKit.assertUnreadable(attacked)
    }

    private func entry(_ type: Int, _ second: Int, _ third: Int) -> String {
        Latin1.string([UInt8(type), UInt8(second >> 24 & 255), UInt8(second >> 16 & 255), UInt8(second >> 8 & 255), UInt8(second & 255),
                       UInt8(third >> 8 & 255), UInt8(third & 255)])
    }

    func test_aListedCopyThatALaterUpdateMovesIntoAnObjectStreamIsStillAShadow() throws {
        let signed = try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(), .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)
        let page = try XCTUnwrap(PdfDocument.open(signed).get(3)).description
        let second = try SignatureTestHelpers.appendRaw(signed, [
            (3, "<</Type /Page /Parent 2 0 R /Contents 60 0 R>>"),
            (60, streamBody(evil)),
        ])

        // The third update lists object 3 again, as the signed text, inside an object stream; the plain copy stays in the file.
        let data = "3 0 " + page
        var text = "\n"
        let stream = second.count + length(text)
        text += "40 0 obj\n<</Type /ObjStm /N 1 /First 4 /Length \(length(data))>>\nstream\n\(data)\nendstream\nendobj\n"
        let table = second.count + length(text)
        let entries = entry(2, 40, 0) + entry(1, stream, 0) + entry(1, table, 0)
        text += "41 0 obj\n<</Type /XRef /Size 61 /W [1 4 2] /Index [3 1 40 2] /Root 1 0 R /Prev \(try PdfDocument.open(second).startXref) /Length \(length(entries))>>\nstream\n\(entries)\nendstream\nendobj\nstartxref\n\(table)\n%%EOF\n"
        let attacked = second + TestPdf.latin(text)

        XCTAssertEqual(try PdfDocument.open(attacked).get(3)?.description, page)
        try assertNotAllowed(attacked)
    }
}
#endif
