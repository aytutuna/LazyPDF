import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactClipRuleTests.cs: the same cases.

final class RedactClipRuleTests: XCTestCase {
    private let gradient = "/Shading <</Sh1 << /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> >> >>"
    private let hole = PdfRect(200, 200, 300, 300)

    private func run(_ content: String, _ resources: String = "", _ mark: PdfRect? = nil) throws -> PdfDocument {
        let document = try RedactionKit.page(content, resources)
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, mark ?? hole)])
        return try RedactionKit.open(result)
    }

    func test_evenOddClipKeepsItsRuleAndItsHole() throws {
        let output = try run("q 100 100 400 400 re 200 200 200 200 re W* n 0 g 0 0 600 800 re f Q", "", PdfRect(120, 120, 150, 150))
        let content = try RedactionKit.latin(output)
        XCTAssertTrue(content.contains("W* n"))
        XCTAssertFalse(content.contains("W n"))
    }

    func test_nonzeroClipPaintedEvenOddKeepsTheNonzeroRule() throws {
        let output = try run("q 100 100 m 400 100 l 257.5 233.5 l h W f* Q")
        XCTAssertFalse(try RedactionKit.latin(output).contains("W*"))
    }

    func test_axialShadingUnderAMarkReachesTheDescriptionOfItsSequence() throws {
        let output = try run("/Figure <</MCID 0 /Alt (ZQXMCALT)>> BDC /Sh1 sh EMC", gradient)
        XCTAssertFalse(try RedactionKit.latin(output).contains("ZQXMCALT"))
    }

    func test_rectangleClipsInsideAMarkAreNotKept() throws {
        let output = try run("q 210 210 2 20 re W n /Sh1 sh Q q 214 210 1 20 re W n /Sh1 sh Q", gradient)
        let content = try RedactionKit.latin(output)
        XCTAssertFalse(content.contains("210 210 2 20 re"))
        XCTAssertFalse(content.contains("214 210 1 20 re"))
    }

    func test_rectangleClipAroundTheWholeMarkIsLeftAlone() throws {
        let output = try run("q 0 0 600 800 re W n /Sh1 sh Q", gradient)
        XCTAssertTrue(try RedactionKit.latin(output).contains("0 0 600 800 re"))
    }
}
