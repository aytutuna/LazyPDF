import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/AnnotationCompareTests.cs: the same cases.

final class AnnotationCompareTests: CompareTestCase {
    private typealias Add = (PdfAnnotationWriter, PdfPage) throws -> Void

    private lazy var text: [[String]] = [page("note")]

    private let box = PdfRect(100, 500, 200, 520)

    /// The page with the annotations `add` puts on it, saved and read again.
    private func withNotes(_ add: Add) throws -> PdfDocument {
        let document = try doc(text)
        try add(PdfAnnotationWriter(document), document.pages[0])
        return try open(document.saveRewrite())
    }

    private func run(_ before: Add, _ after: Add) throws -> ComparisonResult {
        let a = try withNotes(before)
        let b = try withNotes(after)
        return try PdfComparer.compare(a, b)
    }

    private func nothing(_ w: PdfAnnotationWriter, _ p: PdfPage) throws {}

    private func square(_ w: PdfAnnotationWriter, _ p: PdfPage) throws {
        _ = try w.addSquare(p, box, style: AnnotationStyle(), info: AnnotationInfo(author: "a", contents: "first"))
    }

    func test_sameAnnotationsAreNoChange() throws {
        XCTAssertTrue(try run(square, square).isIdentical)
    }

    func test_addedAnnotation() throws {
        let change = try single(try run(nothing, square).changes)
        XCTAssertEqual(change.kind, .added)
        XCTAssertEqual(change.area, .annotation)
        XCTAssertEqual(change.detail, "Square")
        XCTAssertEqual(change.newText, "first")
        _ = try single(change.newQuads)
        XCTAssertTrue(change.oldQuads.isEmpty)
    }

    func test_removedAnnotation() throws {
        let change = try single(try run(square, nothing).changes)
        XCTAssertEqual(change.kind, .removed)
        XCTAssertEqual(change.oldText, "first")
        _ = try single(change.oldQuads)
        XCTAssertTrue(change.newQuads.isEmpty)
    }

    func test_changedCommentTextIsFoundByAnotherCopyOfTheSameNote() throws {
        // Two separately written squares have different names, so this pairs by kind and place.
        let second: Add = { w, p in
            _ = try w.addSquare(p, self.box, style: AnnotationStyle(), info: AnnotationInfo(author: "a", contents: "second"))
        }
        let change = try single(try run(square, second).changes)
        XCTAssertEqual(change.kind, .changed)
        XCTAssertEqual(change.oldText, "first")
        XCTAssertEqual(change.newText, "second")
        XCTAssertTrue(try XCTUnwrap(change.detail).contains(CompareText.annotationText))
    }

    func test_editedNoteIsPairedByName() throws {
        let document = try doc(text)
        let writer = PdfAnnotationWriter(document)
        let note = try writer.addSquare(document.pages[0], box, style: AnnotationStyle(), info: AnnotationInfo(author: "a", contents: "first"))
        let before = try open(document.saveRewrite())
        _ = try writer.move(note, 300, 100)
        _ = try writer.setContents(note, "second")
        _ = try writer.setColor(note, [0, 0, 1])
        let after = try open(document.saveRewrite())
        let change = try single(try PdfComparer.compare(before, after).changes)
        XCTAssertEqual(change.kind, .changed)
        let detail = try XCTUnwrap(change.detail)
        XCTAssertTrue(detail.contains(CompareText.annotationText))
        XCTAssertTrue(detail.contains(CompareText.annotationPosition))
        XCTAssertTrue(detail.contains(CompareText.annotationColor))
        assertInRange(try single(change.newQuads).bounds.left, 399, 401)
    }

    func test_movedNoteIsOneChange() throws {
        let document = try doc(text)
        let writer = PdfAnnotationWriter(document)
        let note = try writer.addCircle(document.pages[0], box)
        let before = try open(document.saveRewrite())
        _ = try writer.move(note, 0, -200)
        let after = try open(document.saveRewrite())
        let change = try single(try PdfComparer.compare(before, after).changes)
        let detail = try XCTUnwrap(change.detail)
        XCTAssertEqual(detail.components(separatedBy: ": ")[1], CompareText.annotationPosition)
    }

    func test_separatelyWrittenCopiesOfANoteAreTheSameNote() throws {
        let markup: Add = { w, p in _ = try w.addNote(p, self.box, AnnotationInfo(author: "a", contents: "text")) }
        XCTAssertTrue(try run(markup, markup).isIdentical)
    }
}
