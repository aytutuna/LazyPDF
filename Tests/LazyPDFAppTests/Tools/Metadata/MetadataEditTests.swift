import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/stamps/MetadataEditTests.cs: the properties and the opening view written through
// the tab, so each save is one undo step.

@MainActor
final class MetadataEditTests: XCTestCase {
    private let now = DateTimeOffset(2026, 11, 4, 9, 30, 0)

    private func open() throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: FakeRenderer(), url: nil, title: "a.pdf")
    }

    func test_theFieldsAndTheViewSurviveACommit() async throws {
        let tab = try open()
        var metadata = DocumentMetadata.read(tab.document)
        metadata.title = "Report"
        metadata.author = "Ayşe Yılmaz"
        metadata.keywords = "a, b"
        var view = ViewerSettings.read(tab.document)
        view.pageMode = .useThumbs
        view.pageLayout = .twoPageRight
        view.displayDocTitle = true
        view.language = "tr-TR"
        view.duplex = "DuplexFlipLongEdge"
        view.numCopies = 3

        try MetadataEdit.write(tab.document, metadata, view, touchModified: false, now: now)
        XCTAssertTrue(try tab.commit("Properties"))

        let read = DocumentMetadata.read(tab.document)
        XCTAssertEqual(read.title, "Report")
        XCTAssertEqual(read.author, "Ayşe Yılmaz")
        XCTAssertEqual(read.keywords, "a, b")
        XCTAssertEqual(ViewerSettings.read(tab.document), view)
    }

    func test_theChangedDateMovesOnlyWhenAsked() async throws {
        let tab = try open()
        var metadata = DocumentMetadata.read(tab.document)
        metadata.title = "A"
        let earlier = try XCTUnwrap(now.addSeconds(-30 * 86_400))
        metadata.modified = earlier
        let view = ViewerSettings.read(tab.document)

        try MetadataEdit.write(tab.document, metadata, view, touchModified: false, now: now)
        try tab.commit("Properties")
        XCTAssertEqual(DocumentMetadata.read(tab.document).modified, earlier)

        metadata.title = "B"
        try MetadataEdit.write(tab.document, metadata, view, touchModified: true, now: now)
        try tab.commit("Properties")
        XCTAssertEqual(DocumentMetadata.read(tab.document).modified, now)
    }

    func test_aCustomEntryIsLeftAloneByAnEditOfTheTitle() async throws {
        let tab = try open()
        var metadata = DocumentMetadata.read(tab.document)
        metadata.custom = ["Project": "Nile"]
        try MetadataEdit.write(tab.document, metadata, ViewerSettings.read(tab.document), touchModified: false, now: now)
        try tab.commit("Properties")

        var retitled = DocumentMetadata.read(tab.document)
        retitled.title = "Nile"
        try MetadataEdit.write(tab.document, retitled, ViewerSettings.read(tab.document), touchModified: false, now: now)
        try tab.commit("Properties")

        XCTAssertEqual(DocumentMetadata.read(tab.document).custom["Project"], "Nile")
    }

    func test_undoBringsTheOldValuesBack() async throws {
        let tab = try open()
        let before = DocumentMetadata.read(tab.document).title
        var metadata = DocumentMetadata.read(tab.document)
        metadata.title = "New"

        try MetadataEdit.write(tab.document, metadata, ViewerSettings.read(tab.document), touchModified: false, now: now)
        try tab.commit("Properties")
        try tab.undo()

        XCTAssertEqual(DocumentMetadata.read(tab.document).title, before)
    }

    func test_clearedOrChangedTextIsDroppedButAddedTextIsNot() async {
        let none = DocumentMetadata(nil, nil, nil, nil, nil, nil, nil, nil, OrderedStrings())
        var old = none
        old.title = "Report"
        old.author = "Ann"
        var cleared = old
        cleared.title = nil
        var changed = old
        changed.author = "Bob"
        var added = old
        added.subject = "Tax"

        XCTAssertTrue(MetadataEdit.dropsText(old, cleared))
        XCTAssertTrue(MetadataEdit.dropsText(old, changed))
        XCTAssertFalse(MetadataEdit.dropsText(old, added))
        XCTAssertFalse(MetadataEdit.dropsText(none, old))
    }

    func test_everyChoiceHasWordsAndNoTwoShareThem() async {
        XCTAssertEqual(Set(MetadataEdit.modes.map(MetadataEdit.modeName)).count, MetadataEdit.modes.count)
        XCTAssertEqual(Set(MetadataEdit.layouts.map(MetadataEdit.layoutName)).count, MetadataEdit.layouts.count)
        XCTAssertEqual(Set(MetadataEdit.sides.map(MetadataEdit.sidesName)).count, MetadataEdit.sides.count)
    }
}
