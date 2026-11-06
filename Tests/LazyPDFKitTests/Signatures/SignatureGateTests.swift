#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureGateTests.cs: the same cases. What the strict reader accepts
// after the signed bytes: each case is an update that is exact but for one thing.

final class SignatureGateTests: XCTestCase {
    private func signed() throws -> [UInt8] {
        try SignatureSharedRoleTests.sign(SignatureSharedRoleTests.doc(), .annotate)
    }

    private func pageText(_ signed: [UInt8]) throws -> String {
        try PdfDocument.open(signed).get(3)?.description ?? ""
    }

    private func entry(_ offset: Int, _ generation: Int = 0, _ type: String = "n") -> String {
        String(format: "%010ld %05ld ", offset, generation) + type + " \n"
    }

    // An update of page 3 with the text it already had, written the way the writers of this layer write one.
    private func update(_ signed: [UInt8], body: String? = nil, entries: String? = nil, trailer: String? = nil, tail: String = "%%EOF\n",
                        startxref: Int? = nil) throws -> [UInt8] {
        let document = try PdfDocument.open(signed)
        let body = try body ?? "3 0 obj\n\(pageText(signed))\nendobj\n"
        let entries = entries ?? "3 1\n\(entry(signed.count))"
        let trailer = trailer ?? "<</Size \(document.nextObjectNumber)\(SignatureRawKit.kept(document)) /Prev \(document.startXref)>>"
        let xref = signed.count + body.unicodeScalars.count
        return signed + TestPdf.latin("\(body)xref\n\(entries)trailer\n\(trailer)\nstartxref\n\(startxref ?? xref)\n\(tail)")
    }

    private func trailer(_ signed: [UInt8], size: String = "", keys: String = "", prev: String = "") throws -> String {
        let document = try PdfDocument.open(signed)
        return "<</Size \(size.isEmpty ? String(document.nextObjectNumber) : size)\(keys.isEmpty ? SignatureRawKit.kept(document) : keys) /Prev \(prev.isEmpty ? String(document.startXref) : prev)>>"
    }

    func test_anUpdateOfExactSyntaxPassesAndAPageRewrittenAsItWasChangesNothing() throws {
        let update = try update(signed())

        XCTAssertTrue(try SignatureRawKit.passesGate(update))
        let report = try SignatureRawKit.check(update)
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.isEmpty)
    }

    func test_oneLineEndAfterTheLastMarkerIsAllThereMayBe() throws {
        let file = try signed()
        for end in ["\n", "\r", "\r\n", ""] {
            XCTAssertTrue(try SignatureRawKit.passesGate(update(file, tail: "%%EOF" + end)), "end \(end.debugDescription)")
        }
    }

    func test_anythingButOneLineEndAfterTheLastMarkerFails() throws {
        let file = try signed()
        for tail in ["%%EOF\n\n", "%%EOF \n", "%%EOF\n%", "%%EOF\n12 0 obj", "%EOF\n", "%%EOFX\n", ""] {
            try SignatureRawKit.assertUnreadable(update(file, tail: tail))
        }
    }

    func test_aTokenOrKeyThatIsNotExactFailsTheUpdate() throws {
        let file = try signed()
        let pages = [
            "<</Type /Page % a comment\n/Parent 2 0 R>>",
            "<</Type /Page /Parent 2 0 R /Contents 4-9 0 R>>",
            "<</Type /Page /Parent 2 0 R /Rotate 1e1>>",
            "<</Type /Page /Parent 2 0 R /Rotate +-1>>",
            "<</Type /Page /Parent 2 0 R /Rotate 1.2.3>>",
            "<</Type /Page /Type /Page /Parent 2 0 R>>",
            "<</Type /Page /Parent 2 0 R /A (unfinished>>",
            "<</Type /Page /Parent 2 0 R /A (bad \\q escape)>>",
            "<</Type /Page /Parent 2 0 R /A <6g>>>",
            "<</Type /Page /Parent 2 0 R /A#zz 1>>",
            "<</Type /Page /Parent 2 0 R /A foo>>",
            "<</Type /Page /Parent 2 0 R /A>>",
            "<</Type /Page /Parent 2 0 R /A [1 R]>>",
            "<</Type /Page /Parent 2 0 R /A 1 0obj>>",
            "<</Type /Page /Parent 2 0 R endobj /Contents 49 0 R>>",
            "<</Type /Page /Parent 2 0 R>> <</Type /Page>>",
            "<</Type /Page /Parent 2 0 R",
        ]
        for page in pages {
            try SignatureRawKit.assertUnreadable(update(file, body: "3 0 obj\n\(page)\nendobj\n"))
        }
    }

    func test_anObjectThatIsNotExactFailsTheUpdate() throws {
        let file = try signed()
        let bodies = [
            "3 0 obj\n<</Type /Page>>\n",
            "3 0 obj\n<</Type /Page>>\nendobj extra\n",
            "3 0 obj\n<</Type /Page>>\nstream\nabc\nendstream\nendobj\n",
            "3 0 obj\n<</Length 3>>\nstream\nabc\nendstream\nendobj\n",
            "3 0 obj\n<</Length 3>>\nstreamabc\nendstream\nendobj\n",
            "3 0 obj\n<</Length 2>>\nstream\nabc\nendstream\nendobj\n",
            "3 0 obj\n<</Length 9 0 R>>\nstream\nabc\nendstream\nendobj\n",
            "3 0 obj\n<</Length 40>>\nstream\nabc\nendstream\nendobj\n",
            "3 0obj\n<<>>\nendobj\n",
            "3 0 obj <<>> endobj\n% between objects\n",
            "0 0 obj\n<<>>\nendobj\n",
        ]
        for body in bodies {
            if body.contains("Length 3>>\nstream\nabc") {
                let fixed = body.replacingOccurrences(of: "<</Length 3>>\nstreamabc", with: "<</Length 3>>\nstream\nabc")
                XCTAssertTrue(try SignatureRawKit.passesGate(update(file, body: fixed)), body)
            }
            try SignatureRawKit.assertUnreadable(update(file, body: body))
        }
    }

    func test_aStreamWithItsLengthWrittenDirectlyPasses() throws {
        let file = try signed()
        let body = "50 0 obj\n<</Length 3>>\nstream\nabc\nendstream\nendobj\n"

        XCTAssertTrue(try SignatureRawKit.passesGate(update(file, body: body, entries: "50 1\n\(entry(file.count))", trailer: trailer(file, size: "51"))))
    }

    func test_aTableEntryMustBeTwentyBytesAndPointAtItsObject() throws {
        let file = try signed()
        let at = file.count

        XCTAssertTrue(try SignatureRawKit.passesGate(update(file)))
        try SignatureRawKit.assertUnreadable(update(file, entries: String(format: "3 1\n%010ld 00000 n\n", at)))
        try SignatureRawKit.assertUnreadable(update(file, entries: String(format: "3 1\n%010ld 00000 n \n", at + 1)))
        try SignatureRawKit.assertUnreadable(update(file, entries: "3 1\n\(entry(at, 1))"))
        try SignatureRawKit.assertUnreadable(update(file, entries: "4 1\n\(entry(at))"))
        try SignatureRawKit.assertUnreadable(update(file, entries: "3 1\n\(entry(5))"))
        try SignatureRawKit.assertUnreadable(update(file, entries: "3 1\n\(entry(3_000_000_000))"))
        try SignatureRawKit.assertUnreadable(update(file, entries: "3 1\n\(entry(at))3 1\n\(entry(at))"))
        try SignatureRawKit.assertUnreadable(update(file, entries: ""))
    }

    func test_anObjectTheTableDoesNotListFailsTheUpdate() throws {
        let file = try signed()
        let page = "3 0 obj\n\(try pageText(file))\nendobj\n"
        let body = page + "60 0 obj\n<<>>\nendobj\n"

        try SignatureRawKit.assertUnreadable(update(file, body: body))
        XCTAssertTrue(try SignatureRawKit.passesGate(update(file, body: body,
            entries: "3 1\n\(entry(file.count))60 1\n\(entry(file.count + page.unicodeScalars.count))", trailer: trailer(file, size: "61"))))
    }

    func test_aFreeEntryPassesAndNamesNoObject() throws {
        let file = try signed()

        XCTAssertTrue(try SignatureRawKit.passesGate(update(file, body: "", entries: "0 1\n\(entry(0, 65535, "f"))9 1\n\(entry(0, 1, "f"))", trailer: trailer(file, size: "10"))))
    }

    func test_theTrailerKeepsTheCatalogAndTheEncryptionAndChainsToTheSectionBefore() throws {
        let file = try signed()
        let document = try PdfDocument.open(file)
        let identity = SignatureRawKit.identity(document)
        let kept = SignatureRawKit.kept(document)

        XCTAssertTrue(try SignatureRawKit.passesGate(update(file, trailer: trailer(file))))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, keys: " /Root 1 3 R\(identity)")))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, keys: " /Root 1-2 0 R\(identity)")))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, keys: " /Root 20 0 R /Root 1 0 R\(identity)")))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, keys: " /Root <</Type /Catalog /Pages 2 0 R>>\(identity)")))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, keys: identity)))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, keys: "\(kept) /XRefStm 5")))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, prev: "12")))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, prev: "\(document.startXref)-5")))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, keys: "\(kept) /Prev 999")))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, size: "3")))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, size: "2")))
    }

    func test_anUpdateChangesTheSecondIdentityStringAndKeepsTheFirst() throws {
        let file = try signed()
        let document = try PdfDocument.open(file)
        let id = try XCTUnwrap(document.trailer["ID"] as? PdfArray)
        let first = id.items[0].description
        func keep(_ identity: String) -> String { " /Root \(document.trailer["Root"]?.description ?? "") /ID [\(identity)]" }

        XCTAssertTrue(try SignatureRawKit.passesGate(update(file, trailer: trailer(file, keys: keep("\(first) <00112233445566778899AABBCCDDEEFF>")))))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, keys: keep("<00112233445566778899AABBCCDDEEFF> \(id.items[1].description)"))))
        try SignatureRawKit.assertUnreadable(update(file, trailer: trailer(file, keys: keep(first))))
    }

    func test_anInformationDictionaryMayBeAddedButNotReplaced() throws {
        let file = try signed()
        let document = try PdfDocument.open(file)
        let kept = SignatureRawKit.kept(document)
        let title = "60 0 obj\n<</Title (x)>>\nendobj\n"
        let entries = "60 1\n\(entry(file.count))"

        XCTAssertTrue(try SignatureRawKit.passesGate(update(file, body: title, entries: entries, trailer: trailer(file, size: "61", keys: kept + " /Info 60 0 R"))))
        let withTitle = SignatureSharedRoleTests.doc()
        withTitle.obj(6, "<</Title (t)>>")
        let withInfo = try PdfSigner.sign(withTitle.finish("/Root 1 0 R /Info 6 0 R"), SignatureKit.request(Pki.instance))
        let swapped = SignatureRawKit.kept(try PdfDocument.open(withInfo)).replacingOccurrences(of: "/Info 6 0 R", with: "/Info 60 0 R")
        try SignatureRawKit.assertUnreadable(update(withInfo, body: title, entries: entries, trailer: trailer(withInfo, size: "61", keys: swapped)))
    }

    func test_theStartxrefMustNameTheSectionThatWasJustRead() throws {
        let file = try signed()

        XCTAssertTrue(try SignatureRawKit.passesGate(update(file)))
        try SignatureRawKit.assertUnreadable(update(file, startxref: 5))
        try SignatureRawKit.assertUnreadable(update(file, startxref: try PdfDocument.open(file).startXref))
    }

    func test_aSignedRevisionThatEndsInsideACommentLeavesTheUpdateUnjudged() throws {
        let file = openSignedTail()

        let update = TestPdf.latin("stream\nBT ET\nendstream\nendobj\nxref\n0 1\n0000000000 65535 f \ntrailer\n<</Size 10 /Root 1 0 R /Prev 100>>\nstartxref\n100\n%%EOF\n")
        let attacked = file + update

        XCTAssertNil(UpdateGate.check(try PdfDocument.open(file), try PdfDocument.open(attacked)))
    }

    // The tail of the signed bytes with a comment that hides the real startxref line; PdfDocument finds the comment's.
    private func openSignedTail() -> [UInt8] {
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
            + (1...4).map { String(format: "%010ld 00000 n \n", starts[$0]) }.joined()
            + String(repeating: "0000000000 00000 f \n", count: 4)
        let trailer = "trailer\n<</Size 10 /Root 1 0 R>>\n"
        let open = xref + head.utf8.count + 20 + trailer.utf8.count
        pdf.write("\(head)" + String(format: "%010ld 00000 n \n", open) + "\(trailer)9 0 obj\n<</Length 10>>\n%startxref \(xref)\n%%EOF\n")
        return pdf.finishWithoutXref()
    }

    func test_anObjectStreamIsReadMemberByMemberAndEveryMemberIsListed() throws {
        let file = try signed()

        XCTAssertTrue(try SignatureRawKit.passesGate(SignatureRawKit.withObjectStream(file, "55 0 (note)", 1, 5, 55, 0)))
        try SignatureRawKit.assertUnreadable(SignatureRawKit.withObjectStream(file, "55 0 56 8 (note) (more)", 2, 10, 55, 0))
        try SignatureRawKit.assertUnreadable(SignatureRawKit.withObjectStream(file, "55 0 x (note)", 1, 7, 55, 0))
        try SignatureRawKit.assertUnreadable(SignatureRawKit.withObjectStream(file, "55 0 (note", 1, 5, 55, 0))
        try SignatureRawKit.assertUnreadable(SignatureRawKit.withObjectStream(file, "55 3    (note)", 1, 5, 55, 0))
        try SignatureRawKit.assertUnreadable(SignatureRawKit.withObjectStream(file, "55 0 (note) (gap)", 1, 5, 55, 0))
        try SignatureRawKit.assertUnreadable(SignatureRawKit.withObjectStream(file, "55 0 (note)", 1, 5, 55, 1))
    }

    func test_anObjectTheUpdateReplacesMustHaveBeenExactInTheSignedBytes() throws {
        let pdf = SignatureSharedRoleTests.doc()
        pdf.obj(6, "<</A 1\n% odd\n>>")
        let file = try SignatureSharedRoleTests.sign(pdf, .annotate)

        XCTAssertFalse(try SignatureRawKit.passesGate(update(file, body: "6 0 obj\n<<>>\nendobj\n", entries: "6 1\n\(entry(file.count))")))
        let next = try PdfDocument.open(file).nextObjectNumber
        XCTAssertTrue(try SignatureRawKit.passesGate(update(file, body: "\(next) 0 obj\n<<>>\nendobj\n", entries: "\(next) 1\n\(entry(file.count))",
                                                           trailer: trailer(file, size: String(next + 1)))))
    }
}
#endif
