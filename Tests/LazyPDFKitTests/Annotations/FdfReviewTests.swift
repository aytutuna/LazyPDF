import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/FdfReviewTests.cs: the same cases.

final class FdfReviewTests: XCTestCase {
    func test_xfdfUsesItsOwnWordsForJustificationSymbolAndReplyType() throws {
        let read = try PdfXfdf.read("<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots><freetext page=\"0\" rect=\"1,1,50,50\" justification=\"centered\"/>"
            + "<caret page=\"0\" rect=\"1,1,5,5\" symbol=\"paragraph\"/><text page=\"0\" rect=\"1,1,5,5\" replyType=\"group\"/></annots></xfdf>")
        let d = read.annotations.map { $0.dictionary }
        XCTAssertEqual((d[0]["Q"] as? PdfNumber)?.integer, 1)
        XCTAssertEqual((d[1]["Sy"] as? PdfName)?.value, "P")
        XCTAssertEqual((d[2]["RT"] as? PdfName)?.value, "Group")

        let xml = String(decoding: try PdfXfdf.write(read), as: UTF8.self)
        XCTAssertTrue(xml.contains("justification=\"centered\""))
        XCTAssertTrue(xml.contains("symbol=\"paragraph\""))
        XCTAssertTrue(xml.contains("replyType=\"group\""))
    }

    func test_aReplyKeepsItsParentWhenTheParentIsAlreadyInTheDocument() throws {
        let epoch = DateTimeOffset(1970, 1, 1, 0, 0, 0)
        let document = try AnnotationFixtures.blank(1)
        let writer = PdfAnnotationWriter(document)
        let note = try writer.addNote(document.pages[0], PdfRect(50, 100, 70, 120), AnnotationInfo(author: "A", contents: "parent", date: epoch))
        let target = try AnnotationFixtures.blank(1)
        try PdfFdf.import(target, try PdfFdf.read(try PdfFdf.write(try PdfFdf.export(document))))

        try PdfComments.reply(document, note, "later", "B", DateTimeOffset(1970, 1, 1, 1, 0, 0))
        try PdfFdf.import(target, try PdfFdf.read(try PdfFdf.write(try PdfFdf.export(document))))

        let list = PdfComments.list(target)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].replies.count, 1)
    }
}
