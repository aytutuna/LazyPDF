import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/ParagraphTests.cs: the same cases, except that the PdfPig assertion of
// LongerTextWrapsInsideTheWidthAndTheBlockGrows has no twin. The theory AlignmentMovesTheLines is one test that loops
// over the three alignments.

final class ParagraphTests: XCTestCase {
    private let lines = [
        "The quick brown fox jumps over",
        "the lazy dog and keeps running",
        "until the end of the day",
    ]

    private func width(_ text: String) throws -> Double {
        let draw = try XCTUnwrap(try PdfFontEmbedder(try PdfDocument.open(TestPdf.simple(1))).add("Helvetica", .regular, [text]))
        return draw.width(text, 12)
    }

    private func left() throws -> PdfEditSession {
        try EditKit.session("BT /F1 12 Tf 14 TL 50 700 Td (" + lines[0] + ") Tj T* (" + lines[1] + ") Tj T* (" + lines[2] + ") Tj ET")
    }

    // {x:0.###}
    private func fixed(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private func aligned(_ x: (String) throws -> Double) throws -> PdfEditSession {
        var content = "BT /F1 12 Tf 1 0 0 1 0 0 Tm "
        for i in 0..<lines.count { content += "1 0 0 1 \(fixed(try x(lines[i]))) \(700 - 14 * i) Tm (\(lines[i])) Tj " }
        return try EditKit.session(content + "ET")
    }

    private func block(_ editor: PageEditor) throws -> TextObject {
        try assertSingle(try editor.objects.compactMap { $0 as? TextObject })
    }

    private func rows(_ session: PdfEditSession) -> [String] {
        TextPage.create(session.document, session.document.pages[0]).lines.sorted { $0.bounds.top > $1.bounds.top }.map { $0.text }
    }

    func test_theBlockIsOneParagraphWithItsStyle() throws {
        let b = try block(try PageEditor(try left(), 0))
        XCTAssertEqual(b.lines.count, 3)
        XCTAssertEqual(b.alignment, .left)
        XCTAssertEqual(b.lineSpacing, 14, accuracy: 0.05)
        XCTAssertEqual(b.size, 12, accuracy: 0.0005)
        XCTAssertEqual(b.font?.name, "Helvetica")
    }

    func test_longerTextWrapsInsideTheWidthAndTheBlockGrows() throws {
        let session = try left()
        let editor = try PageEditor(session, 0)
        let room = try lines.map { try width($0) }.max() ?? 0
        let text = "The quick brown fox jumps over the lazy dog and keeps running until the end of the day, then it sleeps under a tree until the sun is up again"
        let result = try editor.replaceParagraph(try block(editor), text)
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertTrue(result.grew)
        let found = rows(session)
        XCTAssertTrue(found.count > 3)
        XCTAssertEqual(text, found.joined(separator: " "))
        for r in found { XCTAssertTrue(try width(r) <= room + 0.5, r) }
    }

    func test_shorterTextRemovesTheLinesItDoesNotNeed() throws {
        let session = try left()
        let editor = try PageEditor(session, 0)
        let result = try editor.replaceParagraph(try block(editor), "Just one short line")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertFalse(result.grew)
        XCTAssertEqual(rows(session), ["Just one short line"])
    }

    func test_hardBreaksStartNewLines() throws {
        let session = try left()
        let editor = try PageEditor(session, 0)
        _ = try editor.replaceParagraph(try block(editor), "one\ntwo\n\nthree")
        XCTAssertEqual(rows(session), ["one", "two", "three"])
    }

    func test_centeredLinesStayCentered() throws {
        let session = try aligned { 300 - (try self.width($0)) / 2 }
        let editor = try PageEditor(session, 0)
        let b = try block(editor)
        XCTAssertEqual(b.alignment, .center)
        let result = try editor.replaceParagraph(b, "short top\nand a much longer second line of words")
        XCTAssertTrue(result.done, result.problem ?? "")
        for line in TextPage.create(session.document, session.document.pages[0]).lines {
            XCTAssertEqual((line.bounds.left + line.bounds.right) / 2, 300, accuracy: 0.05)
        }
    }

    func test_rightAlignedLinesKeepTheirRightEdge() throws {
        let session = try aligned { 500 - (try self.width($0)) }
        let editor = try PageEditor(session, 0)
        let b = try block(editor)
        XCTAssertEqual(b.alignment, .right)
        let result = try editor.replaceParagraph(b, "a little\nand a much longer second line")
        XCTAssertTrue(result.done, result.problem ?? "")
        for line in TextPage.create(session.document, session.document.pages[0]).lines { XCTAssertEqual(line.bounds.right, 500, accuracy: 0.05) }
    }

    func test_replacingACenteredLineKeepsItCentered() throws {
        let session = try aligned { 300 - (try self.width($0)) / 2 }
        let editor = try PageEditor(session, 0)
        let result = try editor.replaceText(try editor.text.lines[1].range, "x")
        XCTAssertTrue(result.done, result.problem ?? "")
        let line = try XCTUnwrap(TextPage.create(session.document, session.document.pages[0]).lines.first { $0.text == "x" })
        XCTAssertEqual((line.bounds.left + line.bounds.right) / 2, 300, accuracy: 0.05)
    }

    func test_alignmentMovesTheLines() throws {
        for target in [TextAlignment.right, .center, .left] {
            let session: PdfEditSession
            if target == .left {
                session = try aligned { 500 - (try self.width($0)) }
            } else {
                session = try left()
            }
            let editor = try PageEditor(session, 0)
            let result = try editor.setAlignment(try block(editor), target)
            XCTAssertTrue(result.done, "\(target): \(result.problem ?? "")")
            let found = TextPage.create(session.document, session.document.pages[0]).lines
            let b = try block(try PageEditor(session, 0))
            XCTAssertEqual(b.alignment, target)
            XCTAssertEqual(rows(session), lines, "\(target)")
            func edge(_ l: PageLine) -> Double {
                switch target {
                case .right: return l.bounds.right
                case .center: return (l.bounds.left + l.bounds.right) / 2
                default: return l.bounds.left
                }
            }
            let edges = found.map(edge)
            XCTAssertTrue((edges.max() ?? 0) - (edges.min() ?? 0) < 0.5, "\(target)")
        }
    }

    func test_justifyFillsTheWidthOfAllButTheLastLine() throws {
        let session = try left()
        let editor = try PageEditor(session, 0)
        XCTAssertTrue(try editor.setAlignment(try block(editor), .justify).done)
        let found = TextPage.create(session.document, session.document.pages[0]).lines.sorted { $0.bounds.top > $1.bounds.top }
        XCTAssertEqual(found[0].bounds.right, found[1].bounds.right, accuracy: 0.05)
        XCTAssertTrue(found[2].bounds.right < found[1].bounds.right - 5)
        XCTAssertEqual(rows(session), lines)
    }

    func test_lineSpacingMovesTheLinesAndLeavesTheTextAlone() throws {
        let session = try left()
        let editor = try PageEditor(session, 0)
        XCTAssertTrue(try editor.setLineSpacing(try block(editor), 20).done)
        let found = TextPage.create(session.document, session.document.pages[0]).lines.sorted { $0.bounds.top > $1.bounds.top }
        XCTAssertEqual(found[0].bounds.top - found[1].bounds.top, 20, accuracy: 0.05)
        XCTAssertEqual(found[1].bounds.top - found[2].bounds.top, 20, accuracy: 0.05)
        XCTAssertEqual(rows(session), lines)
        XCTAssertEqual(try block(try PageEditor(session, 0)).lineSpacing, 20, accuracy: 0.05)
    }
}
