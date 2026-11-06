#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/FileRevisionTests.cs: the same cases, except that the call of
// `PdfRevisions.extract` with a revision past the end of the file, which the C# expects to throw
// ArgumentOutOfRangeException, is left out: Swift stops with a precondition there, as PORTING.md says for a
// caller's mistake, and a test cannot catch that.

final class FileRevisionTests: XCTestCase {
    private func threeRevisions() throws -> [UInt8] {
        let session = try PdfEditSession.open(SignatureKit.plain())
        _ = try PdfForm.read(session.document).addField(FieldSpec(.text, "Name", 0, PdfRect(40, 200, 240, 224)))
        try session.commit("field")
        _ = try PdfForm.read(session.document).setValue("Name", "Ada")
        try session.commit("fill")
        return session.current
    }

    func test_eachSavedStateOfTheFileIsARevisionThatOpensOnItsOwn() throws {
        let file = try threeRevisions()

        let revisions = PdfRevisions.list(file)

        XCTAssertEqual(revisions.map { $0.number }, [1, 2, 3])
        XCTAssertEqual(revisions[2].end, file.count)
        XCTAssertTrue(revisions[0].end < revisions[1].end && revisions[1].end < revisions[2].end)
        XCTAssertTrue(PdfForm.read(try PdfDocument.open(PdfRevisions.extract(file, revisions[0]))).fields.isEmpty)
        let second = PdfForm.read(try PdfDocument.open(PdfRevisions.extract(file, revisions[1])))
        XCTAssertEqual(try XCTUnwrap(second.find("Name")).value ?? "", "")
        XCTAssertEqual(try XCTUnwrap(PdfForm.read(try PdfDocument.open(PdfRevisions.extract(file, revisions[2]))).find("Name")).value, "Ada")
    }

    func test_revisionsAgreeWithTheVersionsTheEditSessionFinds() throws {
        let file = try threeRevisions()
        let session = try PdfEditSession.open(file)

        XCTAssertEqual(session.versions.map { $0.end }, PdfRevisions.list(file).map { $0.end })
    }

    func test_aSignedFileHasTheRevisionTheSignatureClosed() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(Pki.instance))

        let revisions = PdfRevisions.list(signed)

        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(revisions[1].end, signed.count)
        XCTAssertFalse(try PdfDocument.open(PdfRevisions.extract(signed, revisions[0])).isSigned)
    }

    func test_aStartxrefThatNamesNothingIsNotARevision() throws {
        let file = try threeRevisions()
        let stray = "\nstartxref\n0\n%%EOF\nstartxref\n12\n%%EOF\n"
        let padded = file + Latin1.bytes(stray)

        XCTAssertEqual(PdfRevisions.list(padded).count, 3)

        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
        pdf.stream(3, "", "startxref\n9\n%%EOF\n")
        XCTAssertEqual(PdfRevisions.list(pdf.finish()).count, 1)
    }

    func test_bytesWithoutAFinishedRevisionHaveNone() throws {
        XCTAssertTrue(PdfRevisions.list([]).isEmpty)
        XCTAssertTrue(PdfRevisions.list(Latin1.bytes("%PDF-1.4\n1 0 obj\n<<>>\nendobj\n")).isEmpty)
        let file = try threeRevisions()
        XCTAssertTrue(PdfRevisions.list(Array(file[0..<400])).isEmpty)
    }

    func test_aCutOffTailLeavesTheRevisionsBeforeIt() throws {
        let file = try threeRevisions()
        let revisions = PdfRevisions.list(file)

        let cut = PdfRevisions.list(Array(file[0..<revisions[2].end - 30]))

        XCTAssertEqual(revisions.prefix(2).map { $0.end }, cut.map { $0.end })
    }
}
#endif
