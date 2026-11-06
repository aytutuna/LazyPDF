import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/DocumentCompareTests.cs: the same cases.

final class DocumentCompareTests: CompareTestCase {
    private lazy var text: [[String]] = [page("doc"), page("two")]

    private func edited(_ edit: (PdfDocument) throws -> Void) throws -> PdfDocument {
        let document = try doc(text)
        try edit(document)
        return try open(document.saveRewrite())
    }

    private func run(_ before: (PdfDocument) throws -> Void, _ after: (PdfDocument) throws -> Void) throws -> ComparisonResult {
        let a = try edited(before)
        let b = try edited(after)
        return try PdfComparer.compare(a, b)
    }

    private func nothing(_ d: PdfDocument) throws {}

    private func documentChanges(_ r: ComparisonResult) -> [CompareChange] { r.changes.filter { $0.area == .document } }

    private func byDetail(_ changes: [CompareChange]) throws -> [String: CompareChange] {
        var result: [String: CompareChange] = [:]
        for c in changes { result[try XCTUnwrap(c.detail)] = c }
        return result
    }

    private func title(_ d: PdfDocument, _ title: String) throws {
        var metadata = DocumentMetadata.read(d)
        metadata.title = title
        try metadata.write(d)
    }

    func test_titleAuthorAndCustomKeysAreCompared() throws {
        let result = try run({ d in
            var m = DocumentMetadata.read(d)
            m.title = "Old"
            m.author = "Ann"
            try m.write(d)
        }, { d in
            var m = DocumentMetadata.read(d)
            m.title = "New"
            m.subject = "S"
            m.custom = ["Project": "X"]
            try m.write(d)
        })
        let changes = try byDetail(documentChanges(result))
        let title = try XCTUnwrap(changes["Title"])
        XCTAssertEqual(title.kind, .changed)
        XCTAssertEqual(title.oldText, "Old")
        XCTAssertEqual(title.newText, "New")
        XCTAssertEqual(changes["Author"]?.kind, .removed)
        XCTAssertEqual(changes["Subject"]?.kind, .added)
        XCTAssertEqual(changes["Project"]?.newText, "X")
        for c in changes.values { XCTAssertTrue(c.oldQuads.isEmpty && c.newQuads.isEmpty) }
        XCTAssertEqual(result.summary.document, 4)
    }

    func test_sameMetadataIsNoChange() throws {
        XCTAssertTrue(try run({ try self.title($0, "T") }, { try self.title($0, "T") }).isIdentical)
    }

    func test_pageSizeChangeIsAPageChange() throws {
        let a = try doc(text)
        let file = TestPdf.text(bytes(text.map { $0.map { CompareLine($0) } })).replacingOccurrences(of: "/MediaBox [0 0 612 792]", with: "/MediaBox [0 0 595 842]")
        let b = try open(TestPdf.latin(file))
        let result = try PdfComparer.compare(a, b)
        XCTAssertEqual(result.changes.filter { $0.area == .page && $0.kind == .changed }.count, 2)
        let detail = try XCTUnwrap(result.changes[0].detail)
        XCTAssertTrue(detail.contains("612 x 792"))
        XCTAssertTrue(detail.contains("595 x 842"))
    }

    private func bookmarks(_ d: PdfDocument, _ items: [(title: String, page: Int, level: Int)]) throws {
        let outline = Outline.read(d)
        var parent: OutlineItem?
        for (title, page, level) in items {
            let item = OutlineItem()
            item.title = title
            item.destination = PdfDestination(page)
            if level == 0 {
                parent = try outline.add(item)
            } else {
                try outline.add(item, parent)
            }
        }
        try outline.write(d)
    }

    func test_bookmarksAddedRemovedAndRetitled() throws {
        let result = try run({ try self.bookmarks($0, [("Intro", 0, 0), ("Body", 1, 0), ("Old end", 1, 0)]) },
                             { try self.bookmarks($0, [("Intro", 0, 0), ("Body part", 1, 0), ("Appendix", 1, 0), ("Index", 1, 0)]) })
        let changes = documentChanges(result)
        for c in changes { XCTAssertEqual(c.detail, CompareText.bookmark) }
        let change = try single(changes)
        XCTAssertEqual(change.kind, .changed)
        XCTAssertEqual(change.oldText, "Body; Old end")
        XCTAssertEqual(change.newText, "Body part; Appendix; Index")
    }

    func test_bookmarkThatPointsAtAnotherPage() throws {
        let change = try single(documentChanges(try run({ try self.bookmarks($0, [("Part", 0, 0)]) }, { try self.bookmarks($0, [("Part", 1, 0)]) })))
        XCTAssertEqual(change.detail, CompareText.bookmarkPage)
    }

    func test_bookmarkFollowsAPageThatMoved() throws {
        // Both bookmarks go to the page that holds the same text; the page moved, the bookmark did not change its meaning.
        let a = try doc(text)
        try bookmarks(a, [("Two", 1, 0)])
        let before = try open(a.saveRewrite())
        let b = try doc([text[1], text[0]])
        try bookmarks(b, [("Two", 0, 0)])
        let after = try open(b.saveRewrite())
        let result = try PdfComparer.compare(before, after)
        XCTAssertTrue(documentChanges(result).isEmpty)
    }

    func test_attachmentsAreComparedByContent() throws {
        let result = try run({ d in
            try PdfAttachments.add(d, "a.txt", Array("one".utf8), mimeType: "text/plain")
            try PdfAttachments.add(d, "gone.txt", Array("x".utf8), mimeType: "text/plain")
        }, { d in
            try PdfAttachments.add(d, "a.txt", Array("two".utf8), mimeType: "text/plain")
            try PdfAttachments.add(d, "new.txt", Array("y".utf8), mimeType: "text/plain")
        })
        let changes = try byDetail(documentChanges(result))
        XCTAssertEqual(changes["Attachment a.txt"]?.kind, .changed)
        XCTAssertEqual(changes["Attachment gone.txt"]?.kind, .removed)
        XCTAssertEqual(changes["Attachment new.txt"]?.kind, .added)
    }

    func test_sameAttachmentIsNoChange() throws {
        let add: (PdfDocument) throws -> Void = { d in try PdfAttachments.add(d, "a.txt", Array("one".utf8), mimeType: "text/plain") }
        XCTAssertTrue(try run(add, add).isIdentical)
    }

    private func formField(_ d: PdfDocument, _ name: String, _ value: String?) throws {
        let form = PdfForm.read(d)
        _ = try form.addField(FieldSpec(.text, name, 0, PdfRect(100, 400, 300, 420), value: value))
    }

    func test_formValuesAreCompared() throws {
        let result = try run({ d in
            try self.formField(d, "name", "Ann")
            try self.formField(d, "city", "Rome")
        }, { d in
            try self.formField(d, "name", "Bob")
            try self.formField(d, "zip", "123")
        })
        let changes = try byDetail(documentChanges(result))
        XCTAssertEqual(changes["Form field name"]?.oldText, "Ann")
        XCTAssertEqual(changes["Form field name"]?.newText, "Bob")
        XCTAssertEqual(changes["Form field city"]?.kind, .removed)
        XCTAssertEqual(changes["Form field zip"]?.kind, .added)
    }

    func test_sameFormValuesAreNoChange() throws {
        let fill: (PdfDocument) throws -> Void = { d in try self.formField(d, "name", "Ann") }
        XCTAssertTrue(try run(fill, fill).isIdentical)
    }
}
