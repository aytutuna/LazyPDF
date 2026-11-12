import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/OfficePictureTests.cs.

final class OfficePictureTests: XCTestCase {
    // A JPEG header of 4 by 3 pixels, and a picture file only ExportFakeCodec reads.
    private static let jpeg = "ffd8ffc0000b080003000401011100ffd9"
    private static let png = "50020280808080"
    private static let imageRelationship = "<Relationship Id=\"rIdI1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/a.bin\"/>"

    private static func drawing(_ frame: String = "inline", cx: Int = 1_270_000, cy: Int = 635_000) -> String {
        "<w:r><w:drawing><wp:\(frame)><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:blipFill><a:blip r:embed=\"rIdI1\"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:\(frame)></w:drawing></w:r>"
    }

    private func docx(_ body: String, _ picture: String) throws -> [UInt8] {
        try DocxSpec.package([
            (key: "document", text: body),
            (key: "relationships", text: Self.imageRelationship),
            (key: "bytes word/media/a.bin", text: picture),
        ])
    }

    // The package made into a PDF, with the content stream of every page.
    private func convert(_ package: [UInt8], codec: ImageCodec? = nil) throws -> (made: OfficePdf, contents: [String]) {
        var contents: [String] = []
        let made = try OfficePdfWriter.create(try DocxReader.read(package), OfficeLayoutSpec.fonts(), contents: { _, bytes in contents.append(Latin1.string(bytes)) }, images: codec)
        return (made, contents)
    }

    private func drawn(_ content: String) -> Int { content.components(separatedBy: " Do").count - 1 }

    func test_aJpegIsPlacedAtItsExtent() throws {
        let (made, contents) = try convert(docx("<w:p>\(Self.drawing())</w:p>", Self.jpeg))
        XCTAssertEqual(made.skipped, [])
        XCTAssertEqual(drawn(contents[0]), 1)
        XCTAssertTrue(contents[0].contains("100 0 0 50 "), contents[0])
    }

    func test_otherPicturesNeedTheCodec() throws {
        let body = "<w:p>\(Self.drawing())</w:p>"
        let with = try convert(docx(body, Self.png), codec: ExportFakeCodec())
        XCTAssertEqual(with.made.skipped, [])
        XCTAssertEqual(drawn(with.contents[0]), 1)

        let without = try convert(docx(body, Self.png))
        XCTAssertEqual(without.made.skipped, [SkippedFeature("picture", 1)])
        XCTAssertEqual(drawn(without.contents[0]), 0)
    }

    func test_aBrokenPictureIsCountedAndTheRestIsStillWritten() throws {
        let made = try OfficeConverter.fromWord(docx("<w:p><w:r><w:t>text</w:t></w:r>\(Self.drawing())\(Self.drawing())</w:p>", "0102030405"), OfficeLayoutSpec.fonts(), ExportFakeCodec())
        XCTAssertEqual(made.skipped, [SkippedFeature("picture", 2)])
        let pdf = try PdfDocument.open(made.bytes)
        XCTAssertTrue(TextPage.create(pdf, pdf.pages[0]).text.contains("text"))
    }

    func test_aFloatingPictureIsPlacedInLineAndReported() throws {
        let (made, contents) = try convert(docx("<w:p>\(Self.drawing("anchor"))</w:p>", Self.jpeg))
        XCTAssertEqual(made.skipped, [SkippedFeature("floating-picture", 1)])
        XCTAssertEqual(drawn(contents[0]), 1)
    }

    func test_aRepeatedPictureIsOneImageObject() throws {
        let once = try convert(docx("<w:p>\(Self.drawing())</w:p>", Self.png), codec: ExportFakeCodec())
        let thrice = try convert(docx("<w:p>\(Self.drawing())\(Self.drawing())\(Self.drawing())</w:p>", Self.png), codec: ExportFakeCodec())
        XCTAssertEqual(drawn(thrice.contents[0]), 3)
        XCTAssertLessThan(thrice.made.bytes.count - once.made.bytes.count, 200, "\(thrice.made.bytes.count) against \(once.made.bytes.count)")
    }

    func test_aPictureLargerThanThePageShrinksToIt() throws {
        let document = try DocxReader.read(docx("<w:p>\(Self.drawing(cx: 100_000_000, cy: 50_000_000))</w:p>", Self.jpeg))
        let layout = try Paginator(document, LayoutFonts(OfficeLayoutSpec.fonts())).run()
        XCTAssertEqual(layout.pages.count, 1)
        var images: [PlacedImage] = []
        for case .image(let image) in layout.pages[0].boxes { images.append(image) }
        XCTAssertEqual(images.count, 1)
        XCTAssertLessThanOrEqual(images[0].width, 468.01)
        XCTAssertEqual(images[0].width / images[0].height, 2, accuracy: 0.01)
    }

    func test_onlyTheFirst2000PicturesAreKept() throws {
        let body = String(repeating: "<w:p>\(Self.drawing())</w:p>", count: 2005)
        let document = try DocxReader.read(docx(body, Self.jpeg))
        var kept = 0
        for section in document.sections {
            for case let p as LayoutParagraph in section.blocks { kept += p.runs.filter { $0.picture != nil }.count }
        }
        XCTAssertEqual(kept, 2000)
        XCTAssertTrue(document.skipped.contains { $0.kind == "picture" && $0.count == 5 })
    }

    private static func band(_ root: String, _ text: String) -> String {
        "<w:\(root) xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:\(root)>"
    }

    func test_firstAndEvenPagesUseTheirOwnHeaders() throws {
        let rels = Self.imageRelationship +
            "<Relationship Id=\"rIdH2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header2.xml\"/>" +
            "<Relationship Id=\"rIdH3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header3.xml\"/>"
        let page = "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
        let body = "<w:p><w:r><w:t>one</w:t></w:r></w:p>" + page + "<w:p><w:r><w:t>two</w:t></w:r></w:p>" + page + "<w:p><w:r><w:t>three</w:t></w:r></w:p>" + page +
            "<w:sectPr><w:headerReference w:type=\"default\" r:id=\"rIdH\"/><w:headerReference w:type=\"first\" r:id=\"rIdH2\"/><w:headerReference w:type=\"even\" r:id=\"rIdH3\"/><w:titlePg/></w:sectPr>"
        let parts = [
            (key: "document", text: body),
            (key: "relationships", text: rels),
            (key: "header", text: "<w:p><w:r><w:t>Odd</w:t></w:r></w:p>"),
            (key: "part word/header2.xml", text: Self.band("hdr", "First")),
            (key: "part word/header3.xml", text: Self.band("hdr", "Even")),
            (key: "settings", text: "<w:evenAndOddHeaders/>"),
        ]
        let made = try OfficeConverter.fromWord(DocxSpec.package(parts), OfficeLayoutSpec.fonts())
        let pdf = try PdfDocument.open(made.bytes)
        XCTAssertEqual(pdf.pages.count, 4)
        let expected = ["First", "Even", "Odd", "Even"]
        for i in 0..<4 { XCTAssertTrue(TextPage.create(pdf, pdf.pages[i]).text.hasPrefix(expected[i]), "page \(i + 1)") }
    }
}
