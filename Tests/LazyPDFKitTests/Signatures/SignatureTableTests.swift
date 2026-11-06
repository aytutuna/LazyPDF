#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureTableTests.cs: the same cases. What the update's tables,
// trailers and object streams say that the reader's own view of them leaves out.

final class SignatureTableTests: XCTestCase {
    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureRawKit.check(file) }

    private func signed() throws -> [UInt8] { try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(), .noChanges) }

    private func length(_ text: String) -> Int { text.unicodeScalars.count }

    private func offset(_ value: Int) -> String { String(format: "%010ld", value) }

    // The trailer the test writes, with the identity of the file it follows added before its end.
    private func closed(_ signed: [UInt8], _ trailer: (Int) -> String) throws -> String {
        let document = try PdfDocument.open(signed)
        let text = trailer(document.startXref)
        return String(text.dropLast(2)) + SignatureRawKit.identity(document) + ">>"
    }

    // An update with a second catalog and a trailer written as given.
    private func withTrailer(_ signed: [UInt8], _ trailer: (Int) -> String) throws -> [UInt8] {
        var text = "\n"
        let catalog = signed.count + length(text)
        text += "12 0 obj\n<</Type /Catalog /Pages 13 0 R>>\nendobj\n"
        let pages = signed.count + length(text)
        text += "13 0 obj\n<</Type /Pages /Kids [] /Count 0>>\nendobj\n"
        let table = signed.count + length(text)
        text += "xref\n12 2\n\(offset(catalog)) 00000 n \n\(offset(pages)) 00000 n \ntrailer\n\(try closed(signed, trailer))\nstartxref\n\(table)\n%%EOF\n"
        return signed + TestPdf.latin(text)
    }

    func test_aTrailerRootWithASignInsideTheNumberIsNotAllowed() throws {
        let attacked = try withTrailer(signed()) { prev in "<</Size 40 /Root 1-2 0 R /Prev \(prev)>>" }

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aTrailerKeyAfterAnEndobjIsNotAllowed() throws {
        let attacked = try withTrailer(signed()) { prev in "<</Size 40 /Prev \(prev) /Root 1 0 R endobj /Root 12 0 R>>" }

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aPrevWithASignInsideTheNumberIsNotAllowed() throws {
        let attacked = try withTrailer(signed()) { prev in "<</Size 40 /Root 1 0 R /Prev \(prev)-5>>" }

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aRepeatedPrevIsNotAllowed() throws {
        let attacked = try withTrailer(signed()) { prev in "<</Size 40 /Root 1 0 R /Prev 999 /Prev \(prev)>>" }

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aNumberListedTwiceInOneTableIsNotAllowed() throws {
        let signed = try self.signed()
        let document = try PdfDocument.open(signed)
        let good = try XCTUnwrap(document.entries[3]).offset
        let page = try XCTUnwrap(document.get(3)).description.replacingOccurrences(of: "/Contents 4 0 R", with: "/Contents 49 0 R")
        let inner = "\n3 0 obj\n\(page)\nendobj\n"
        var text = "\n"
        let holder = signed.count + length(text)
        let head = "50 0 obj\n<</Length \(length(inner))>>\nstream\n"
        text += head + inner + "\nendstream\nendobj\n"
        let hidden = holder + length(head) + 1
        let stream = signed.count + length(text)
        text += "49 0 obj\n\(SignatureRawKit.streamBody(SignatureRawKit.evil))\nendobj\n"
        let table = signed.count + length(text)
        text += "xref\n3 1\n\(offset(good)) 00000 n \n3 1\n\(offset(hidden)) 00000 n \n49 2\n\(offset(stream)) 00000 n \n\(offset(holder)) 00000 n \n"
        text += "trailer\n<</Size 51\(SignatureRawKit.kept(document)) /Prev \(document.startXref)>>\nstartxref\n\(table)\n%%EOF\n"

        try SignatureRawKit.assertUnreadable(signed + TestPdf.latin(text))
    }

    private func stampedDoc() -> TestPdf {
        let pdf = SignatureSharedRoleTests.doc(page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40] /Contents (VOID)>>")
        return pdf
    }

    func test_anEntryThatLeadsToAnotherObjectIsNotAllowed() throws {
        for (intoSigned, closed) in [(true, true), (true, false), (false, false)] {
            let signed = try SignatureSharedRoleTests.sign(stampedDoc(), .noChanges)
            let at = intoSigned ? 5 : signed.count + 1
            var attacked = try SignatureForgeryTests.appendSection(signed, intoSigned ? "" : "% nothing here\n", "6 1\n\(offset(at)) 00000 n \n")
            if !closed {
                let end = try XCTUnwrap(SignatureObjects.lastIndex(attacked, "%%EOF"))
                attacked = Array(attacked[0..<end])
            }

            try SignatureRawKit.assertUnreadable(attacked)
        }
    }

    func test_anEntryWithAnOffsetPastTheIntRangeIsAChangeAndNotACrash() throws {
        let attacked = try SignatureForgeryTests.appendSection(signed(), "", "77 1\n3000000000 00000 n \n")

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aMemberOfAnObjectStreamIsReadFromItsOwnStart() throws {
        let signed = try self.signed()
        let page = try XCTUnwrap(PdfDocument.open(signed).get(3)).description.replacingOccurrences(of: "/Contents 4 0 R", with: "/Contents 4-9 0 R")

        for gap in ["3 0 endobj ", "3 0 ( "] {
            try SignatureRawKit.assertUnreadable(SignatureRawKit.withObjectStream(signed, gap + page, 1, length(gap), 3, 0,
                                                                                  [(49, SignatureRawKit.streamBody(SignatureRawKit.evil))]))
        }
    }

    func test_anObjectStreamThatListsANumberTwiceIsNotAllowed() throws {
        let signed = try self.signed()
        let good = try XCTUnwrap(PdfDocument.open(signed).get(3)).description
        let evil = good.replacingOccurrences(of: "/Contents 4 0 R", with: "/Contents 49 0 R")
        let head = "3 0 3 \(length(good) + 1) "

        let attacked = try SignatureRawKit.withObjectStream(signed, head + good + " " + evil, 2, length(head), 3, 1,
                                                            [(49, SignatureRawKit.streamBody(SignatureRawKit.evil))])

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_anEntryThatNamesTheWrongMemberOfAnObjectStreamIsNotAllowed() throws {
        let signed = try self.signed()
        let good = try XCTUnwrap(PdfDocument.open(signed).get(3)).description
        let evil = good.replacingOccurrences(of: "/Contents 4 0 R", with: "/Contents 49 0 R")
        let head = "7 0 3 \(length(evil) + 1) "

        let attacked = try SignatureRawKit.withObjectStream(signed, head + evil + " " + good, 2, length(head), 3, 0,
                                                            [(49, SignatureRawKit.streamBody(SignatureRawKit.evil))])

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_aWellFormedObjectStreamWithANewMemberIsNotReported() throws {
        let signed = try self.signed()
        let head = "55 0 "

        let update = try SignatureRawKit.withObjectStream(signed, head + "(note)", 1, length(head), 55, 0)

        // The bytes are exact; a member that nothing refers to is still not something the signer allowed.
        XCTAssertTrue(try SignatureRawKit.passesGate(update))
        let report = try check(update)
        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .other && $0.object == 55 })
    }

    func test_anEndobjInsideADictionaryHidesWhatFollowsIt() throws {
        let signed = try self.signed()
        let page = try XCTUnwrap(PdfDocument.open(signed).get(3)).description
        let attacked = try SignatureTestHelpers.appendRaw(signed, [
            (3, String(page.dropLast(2)) + " endobj /Contents 49 0 R>>"),
            (49, SignatureRawKit.streamBody(SignatureRawKit.evil)),
        ])

        try SignatureRawKit.assertUnreadable(attacked)
    }

    func test_anEntryMovedBackToAnOlderCopyWithAnOddNumberIsNotAllowed() throws {
        let pdf = SignatureSharedRoleTests.doc()
        let old = pdf.position
        pdf.write("3 0 obj\n<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4-9 0 R>>\nendobj\n")
        pdf.obj(6, "<<>>")
        let before = pdf.finish()
        let document = try PdfDocument.open(before)
        let evil = before.count + 1
        var text = "\n49 0 obj\n\(SignatureRawKit.streamBody(SignatureRawKit.evil))\nendobj\n"
        let table = before.count + length(text)
        text += "xref\n3 1\n\(offset(old)) 00000 n \n49 1\n\(offset(evil)) 00000 n \ntrailer\n<</Size 50\(SignatureRawKit.kept(document)) /Prev \(document.startXref)>>\nstartxref\n\(table)\n%%EOF\n"
        let after = before + TestPdf.latin(text)

        XCTAssertTrue(try SignatureOverlapTests.compare(before, after, 1).notAllowed.contains { $0.kind == .unreadable })
    }
}
#endif
