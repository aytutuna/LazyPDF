import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactClipTests.cs: the same cases.

final class RedactClipTests: XCTestCase {
    private let gradient = "/Shading <</Sh1 << /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 600 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1 >> >> >>"
    private let hole = PdfRect(200, 200, 300, 300)

    private func run(_ content: String, _ resources: String = "") throws -> (RedactionResult, PdfDocument) {
        let document = try RedactionKit.page(content, resources)
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, hole)])
        return (result, try RedactionKit.open(result))
    }

    private func points(_ path: PathInfo) -> [MarkPoint] {
        path.segments.filter { $0.kind == .move || $0.kind == .line }.map { ($0.x1, $0.y1) }
    }

    func test_clipOutlineInsideTheMarkIsNotKept() throws {
        let (_, output) = try run("q 100 100 m 400 100 l 257.5 233.5 l h W n /Sh1 sh Q", gradient)
        XCTAssertFalse(try RedactionKit.latin(output).contains("257.5 233.5"))
        let clips = try ContentTestPdf.run(output).paths.filter { $0.path.clips }
        XCTAssertFalse(clips.isEmpty)
        for p in clips.flatMap({ points($0.path) }) {
            XCTAssertFalse(p.x > 200.01 && p.x < 299.99 && p.y > 200.01 && p.y < 299.99)
        }
        XCTAssertTrue(clips.contains { $0.path.bounds.left <= 100.01 })
    }

    func test_pathThatClipsAndFillsKeepsNoCoordinatesInsideTheMark() throws {
        let (result, output) = try run("q 1 0 0 rg 100 100 m 400 100 l 257.5 233.5 l h W f 0 g 10 10 20 20 re f Q")
        let content = try RedactionKit.latin(output)
        XCTAssertFalse(content.contains("257.5 233.5"))
        XCTAssertTrue(content.contains("W"))
        XCTAssertEqual(result.report.paths, 1)
    }

    func test_clipWhollyInsideTheMarkClipsToNothing() throws {
        let (_, output) = try run("q 230 210 m 270 210 l 257.5 233.5 l h W n 0 g 10 10 20 20 re f Q")
        XCTAssertFalse(try RedactionKit.latin(output).contains("257.5 233.5"))
        let found = try ContentTestPdf.run(output).paths.filter { $0.path.bounds.left == 10 }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].state.clip.width, 0, accuracy: 0.001)
        XCTAssertEqual(found[0].state.clip.height, 0, accuracy: 0.001)
    }

    func test_clipOutsideTheMarkIsLeftAlone() throws {
        let (_, output) = try run("q 100 400 m 400 400 l 257.5 533.5 l h W n /Sh1 sh Q", gradient)
        XCTAssertTrue(try RedactionKit.latin(output).contains("257.5 533.5"))
    }
}
