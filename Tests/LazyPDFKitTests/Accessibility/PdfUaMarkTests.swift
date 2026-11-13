import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/PdfUaMarkTests.cs: the same cases.

final class PdfUaMarkTests: XCTestCase {
    private let unmarked = PdfUaKit.build(viewer: "", xmp: PdfUaKit.packet(ua: false))

    private func mark(_ document: PdfDocument) throws -> PdfUaMarkResult { try PdfUaValidator.mark(document, PdfUaKit.date) }

    private func reopen(_ document: PdfDocument) throws -> PdfDocument { try PdfDocument.open(try document.saveRewrite()) }

    private func packet(_ document: PdfDocument) throws -> String {
        String(decoding: try document.data(document.stream(document.catalog, "Metadata")!), as: UTF8.self)
    }

    func test_aFileThatPassesButForTheMarksIsMarked() throws {
        let document = try PdfDocument.open(unmarked)

        let result = try mark(document)

        XCTAssertTrue(result.marked)
        XCTAssertTrue(result.blocking.isValid)
        let saved = try reopen(document)
        let report = try PdfUaValidator.validate(saved)
        XCTAssertTrue(report.isValid, PdfUaKit.describe(report))
        XCTAssertTrue(ViewerSettings.read(saved).displayDocTitle)
    }

    func test_aFileWithoutMetadataGetsAPacketFromInfo() throws {
        let document = try PdfDocument.open(PdfUaKit.build(xmp: ""))
        XCTAssertTrue(try PdfUaValidator.validate(document).issues.contains { $0.condition == "06-001" })

        XCTAssertTrue(try mark(document).marked)

        let saved = try reopen(document)
        XCTAssertTrue(try PdfUaValidator.validate(saved).isValid)
        XCTAssertEqual(DocumentMetadata.read(saved).title, "Title")
    }

    func test_aFileThatFailsAnythingElseIsLeftAlone() throws {
        let document = try PdfDocument.open(PdfUaKit.build(lang: "", viewer: "", xmp: PdfUaKit.packet(ua: false)))

        let result = try mark(document)

        XCTAssertFalse(result.marked)
        XCTAssertTrue(result.blocking.issues.contains { $0.condition == "11-006" })
        XCTAssertFalse(result.blocking.issues.contains { $0.condition == "06-002" || $0.condition == "07-001" })
        XCTAssertFalse(ViewerSettings.read(document).displayDocTitle)
        XCTAssertFalse(try packet(document).contains("pdfuaid"))
    }

    func test_withoutATitleThereIsNothingToShow() throws {
        let document = try PdfDocument.open(PdfUaKit.build(viewer: "", xmp: PdfUaKit.packet(ua: false, title: false), info: "<</Creator (Test)>>"))

        let result = try mark(document)

        XCTAssertFalse(result.marked)
        XCTAssertEqual(result.blocking.issues.map { $0.condition }, ["06-003"])
    }

    func test_aTitleInInfoReachesTheXmp() throws {
        let document = try PdfDocument.open(PdfUaKit.build(viewer: "", xmp: PdfUaKit.packet(ua: false, title: false)))

        XCTAssertTrue(try mark(document).marked)

        XCTAssertTrue(try PdfUaValidator.validate(try reopen(document)).isValid)
    }

    func test_anEmptyTitleInTheXmpTakesTheInfoTitle() throws {
        let packet = PdfUaKit.packet(ua: false).replacingOccurrences(of: ">Title</rdf:li>", with: "></rdf:li>")
        let document = try PdfDocument.open(PdfUaKit.build(viewer: "", xmp: packet))
        XCTAssertTrue(try PdfUaValidator.validate(document).issues.contains { $0.condition == "06-003" })

        XCTAssertTrue(try mark(document).marked)

        XCTAssertTrue(try PdfUaValidator.validate(try reopen(document)).isValid)
    }

    func test_markingTwiceChangesNothingTheSecondTime() throws {
        let document = try PdfDocument.open(unmarked)
        _ = try mark(document)
        let once = try reopen(document)

        XCTAssertTrue(try mark(once).marked)

        XCTAssertEqual(try packet(once).components(separatedBy: "<pdfuaid:part>").count - 1, 1)
    }

    func test_aPdfAFileStaysPdfAWithTheExtensionSchema() throws {
        let file = StandardsKit.tagged(.a2b)
        XCTAssertTrue(try StandardsKit.check(file, .a2b).isValid)
        let document = try PdfDocument.open(file)

        XCTAssertTrue(try mark(document).marked)

        let saved = try reopen(document)
        XCTAssertTrue(try PdfUaValidator.validate(saved).isValid)
        let pdfa = PdfAValidator.validate(saved, .a2b)
        XCTAssertTrue(pdfa.isValid, pdfa.issues.map { "\($0.clause) \($0.where): \($0.message)" }.joined(separator: "\n"))
        XCTAssertTrue(try packet(saved).contains("PDF/UA identification schema"))
    }
}
