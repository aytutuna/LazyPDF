import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/SanitizeTextTests.cs: the same cases. The PdfPig text assertion of
// RenderModeThreeStaysUnlessAskedFor has no twin; the engine's text stands in for it.

final class SanitizeTextTests: XCTestCase {
    private let resources = "/Font <</F1 5 0 R>> /XObject <</Im0 6 0 R>>"

    private func page(_ content: String) -> [UInt8] {
        OptimizeKit.build(content, resources, { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", "H")
        })
    }

    private func run(_ file: [UInt8], _ options: SanitizeOptions = SanitizeOptions()) throws -> SanitizeResult {
        let document = try PdfDocument.open(file)
        return try PdfSanitizer(document).run(options)
    }

    func test_whiteTextOnABlankPageIsReportedNotRemoved() throws {
        let result = try run(page("1 g BT /F1 12 Tf 10 100 Td (WHITEWORDS) Tj ET 0 g BT /F1 12 Tf 10 50 Td (BLACKWORDS) Tj ET"))
        XCTAssertEqual(1, SanitizeKit.count(result.kept, .hiddenText))
        XCTAssertEqual(0, SanitizeKit.count(result.removed, .hiddenText))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "WHITEWORDS"))
    }

    func test_whiteTextOnADarkAreaIsNotHidden() throws {
        let result = try run(page("0 g 0 0 200 200 re f 1 g BT /F1 12 Tf 10 100 Td (ONBLACK) Tj ET"))
        XCTAssertEqual(0, SanitizeKit.count(result.kept, .hiddenText))
    }

    func test_textUnderALaterPictureIsReported() throws {
        let result = try run(page("BT /F1 12 Tf 10 100 Td (BEHINDPICTURE) Tj ET q 200 0 0 200 0 0 cm /Im0 Do Q"))
        XCTAssertEqual(1, SanitizeKit.count(result.kept, .hiddenText))
    }

    func test_textAfterAPictureIsNotHidden() throws {
        let result = try run(page("q 200 0 0 200 0 0 cm /Im0 Do Q BT /F1 12 Tf 10 100 Td (ABOVEPICTURE) Tj ET"))
        XCTAssertEqual(0, SanitizeKit.count(result.kept, .hiddenText))
    }

    func test_renderModeThreeStaysUnlessAskedFor() throws {
        let file = page("BT /F1 12 Tf 3 Tr 10 100 Td (OCRLAYER) Tj ET BT 0 Tr 10 50 Td (shown) Tj ET")
        let kept = try run(file)
        XCTAssertTrue(try OptimizeKit.everywhere(kept.bytes, "OCRLAYER"))
        XCTAssertEqual(1, SanitizeKit.count(kept.kept, .invisibleText))
        let removed = try run(file, SanitizeOptions(invisibleText: true))
        XCTAssertFalse(try OptimizeKit.everywhere(removed.bytes, "OCRLAYER"))
        XCTAssertEqual(1, SanitizeKit.count(removed.removed, .invisibleText))
        XCTAssertEqual("shown", try OptimizeKit.engineText(removed.bytes).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func test_quoteOperatorsKeepTheirLineMove() throws {
        let file = page("BT /F1 12 Tf 14 TL 10 150 Td 3 Tr (OCRONE) Tj (OCRTWO) ' ET BT 0 Tr 10 50 Td (below) Tj ET")
        let result = try run(file, SanitizeOptions(invisibleText: true))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "OCRTWO"))
        XCTAssertEqual(2, SanitizeKit.count(result.removed, .invisibleText))
        XCTAssertTrue(try OptimizeKit.engineText(result.bytes).contains("below"))
    }

    func test_aTextObjectThatAlsoShowsVisibleTextIsLeft() throws {
        let file = page("BT /F1 12 Tf 10 100 Td 3 Tr (OCRMIXED) Tj 0 Tr ( visible) Tj ET")
        let result = try run(file, SanitizeOptions(invisibleText: true))
        XCTAssertTrue(try OptimizeKit.everywhere(result.bytes, "OCRMIXED"))
        XCTAssertEqual(1, SanitizeKit.count(result.kept, .invisibleText))
    }

    func test_invisibleTextInAFormIsRemovedToo() throws {
        let file = OptimizeKit.build("q /Fm0 Do Q", "/XObject <</Fm0 6 0 R>>", { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 3 Tr (OCRINFORM) Tj ET")
        })
        let result = try run(file, SanitizeOptions(invisibleText: true))
        XCTAssertFalse(try OptimizeKit.everywhere(result.bytes, "OCRINFORM"))
    }
}
