import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/RevisionDiffTests.cs: which pages an edit can have changed, found from the bytes the edit
// session appended.

final class RevisionDiffTests: XCTestCase {
    private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    func test_theObjectsDefinedInTheAppendedPartAreTheChangedOnes() {
        let before = ascii("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n")
        let after = before + ascii("12 0 obj\n<< /A 1 >>\nendobj\n7 3 obj\n(x)\nendobj\nxref\n")

        let changed = RevisionDiff.changed(before, after)

        XCTAssertEqual(changed?.sorted(), [7, 12])
    }

    func test_theSameObjectsAreFoundWhenTheLongerBufferIsTheOldOne() {
        let shorter = ascii("%PDF-1.7\n1 0 obj\n<<>>\nendobj\n")
        let longer = shorter + ascii("5 0 obj\n<<>>\nendobj\n")

        XCTAssertEqual(RevisionDiff.changed(longer, shorter), [5])
    }

    func test_buffersWhereNeitherBeginsWithTheOtherAreAllChanged() {
        XCTAssertNil(RevisionDiff.changed(ascii("%PDF-1.7 one"), ascii("%PDF-1.7 two, longer")))
    }

    func test_identicalBuffersChangeNothing() {
        XCTAssertEqual(RevisionDiff.changed(ascii("%PDF-1.7\n1 0 obj\n"), ascii("%PDF-1.7\n1 0 obj\n")), [])
    }

    func test_aTitleChangeTouchesNoPage() throws {
        let session = try PdfEditSession.open(try TestPdfs.text(pages: 2))
        let before = session.current
        try TestPdfs.retitle(session, "Another title")
        _ = try session.commit("Title")

        let changed = try XCTUnwrap(RevisionDiff.changed(before, session.current))

        XCTAssertFalse(changed.isEmpty)
        XCTAssertFalse(RevisionDiff.touches(session.document, session.document.pages[0], changed))
        XCTAssertFalse(RevisionDiff.touches(session.document, session.document.pages[1], changed))
    }

    func test_aNoteOnOnePageTouchesThatPageOnly() throws {
        let session = try PdfEditSession.open(try TestPdfs.text(pages: 3))
        let before = session.current
        try TestPdfs.addNote(session, page: 1)
        _ = try session.commit("Note")

        let changed = try XCTUnwrap(RevisionDiff.changed(before, session.current))

        let document = session.document
        XCTAssertFalse(RevisionDiff.touches(document, document.pages[0], changed))
        XCTAssertTrue(RevisionDiff.touches(document, document.pages[1], changed))
        XCTAssertFalse(RevisionDiff.touches(document, document.pages[2], changed))
    }

    func test_undoFindsTheSamePage() throws {
        let session = try PdfEditSession.open(try TestPdfs.text(pages: 2))
        try TestPdfs.addNote(session, page: 0)
        _ = try session.commit("Note")
        let committed = session.current

        _ = try session.undo()
        let changed = try XCTUnwrap(RevisionDiff.changed(committed, session.current))

        XCTAssertTrue(RevisionDiff.touches(session.document, session.document.pages[0], changed))
        XCTAssertFalse(RevisionDiff.touches(session.document, session.document.pages[1], changed))
    }

    // The page draws a form XObject that its resource dictionary names /P, a key the walk skips in a page's own dictionary.
    private func pageWithResourceNamedP() throws -> PdfDocument {
        try PdfDocument.open(ascii(
            "%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
            + "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
            + "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /XObject << /P 5 0 R /Parent 6 0 R >> >> /Contents 4 0 R >>\nendobj\n"
            + "4 0 obj\n<< /Length 5 >>\nstream\n/P Do\nendstream\nendobj\n"
            + "5 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Length 0 >>\nstream\n\nendstream\nendobj\n"
            + "6 0 obj\n<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Length 0 >>\nstream\n\nendstream\nendobj\n"
            + "trailer\n<< /Root 1 0 R /Size 7 >>\n%%EOF\n"))
    }

    func test_aResourceNamedLikeALeavingKeyIsStillFollowed() throws {
        for changedObject in [5, 6] {
            let document = try pageWithResourceNamedP()

            XCTAssertTrue(RevisionDiff.touches(document, document.pages[0], [changedObject]), "\(changedObject)")
        }
    }

    func test_anObjectNoPageUsesTouchesNothing() throws {
        let document = try pageWithResourceNamedP()

        XCTAssertFalse(RevisionDiff.touches(document, document.pages[0], [99]))
    }

    func test_aWalkThatRunsOutOfBudgetCountsAsTouched() throws {
        var file = "%PDF-1.7\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
        let refs = (10..<6010).map { "\($0) 0 R" }.joined(separator: " ")
        file += "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] /Resources << /Other [\(refs)] >> >>\nendobj\n"
        for n in 10..<6010 { file += "\(n) 0 obj\n<< >>\nendobj\n" }
        file += "trailer\n<< /Root 1 0 R /Size 6010 >>\n%%EOF\n"
        let document = try PdfDocument.open(ascii(file))

        XCTAssertTrue(RevisionDiff.touches(document, document.pages[0], [99999]))
    }

    func test_aSaveWithoutHistoryIsASeparateFile() throws {
        let session = try PdfEditSession.open(try TestPdfs.text(pages: 2))
        try TestPdfs.retitle(session, "Titled")
        _ = try session.commit("Title")
        let before = session.current

        try session.saveCompact(temporaryFile("small.pdf", for: self))

        XCTAssertNil(RevisionDiff.changed(before, session.current))
    }
}
