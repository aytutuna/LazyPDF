import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/TextBoxTests.cs: the same cases, except that the two assertions that PdfPig
// reads the words back have no twin. The font behind "Arial" is EditFont, which has the Turkish letters of the test. The
// theories are tests that loop over their cases.

final class TextBoxTests: XCTestCase {
    private let words = "The quick brown fox jumps over the lazy dog and keeps running until the end of the day"

    func test_textWrapsInsideTheBoxFromItsTop() throws {
        let session = try EditKit.session("")
        let result = try PageEditor(session, 0).addTextBox(PdfRect(100, 500, 250, 600), words, TextBoxStyle(size: 12))
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertFalse(result.overlaps)
        let text = TextPage.create(session.document, session.document.pages[0])
        XCTAssertTrue(text.lines.count > 2)
        XCTAssertEqual(text.lines.map { $0.text }.joined(separator: " "), words)
        for l in text.lines {
            XCTAssertTrue(l.bounds.left >= 99.9 && l.bounds.right <= 250.1, l.text)
            XCTAssertTrue(l.bounds.top <= 600.5)
        }
    }

    func test_aTallTextIsReportedAsTooLarge() throws {
        let session = try EditKit.session("")
        let result = try PageEditor(session, 0).addTextBox(PdfRect(100, 580, 250, 600), words)
        XCTAssertTrue(result.done)
        XCTAssertTrue(result.overlaps)
    }

    func test_turkishTextUsesTheFontSource() throws {
        let session = try EditKit.session("")
        let result = try PageEditor(session, 0, EditArialSource()).addTextBox(PdfRect(50, 600, 400, 700), "Çalışma ğüzel İstanbul şehri", TextBoxStyle(family: "Arial", size: 14))
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertTrue(try EditKit.text(session).contains("Çalışma ğüzel İstanbul şehri"))
    }

    func test_linesFollowTheAlignment() throws {
        for alignment in [TextAlignment.left, .center, .right] {
            let session = try EditKit.session("")
            _ = try PageEditor(session, 0).addTextBox(PdfRect(100, 500, 300, 600), "short\na somewhat longer line", TextBoxStyle(alignment: alignment))
            let lines = TextPage.create(session.document, session.document.pages[0]).lines.sorted { $0.bounds.top > $1.bounds.top }
            func edge(_ l: PageLine) -> Double {
                switch alignment {
                case .right: return l.bounds.right
                case .center: return (l.bounds.left + l.bounds.right) / 2
                default: return l.bounds.left
                }
            }
            XCTAssertEqual(edge(lines[0]), edge(lines[1]), accuracy: 0.05, "\(alignment)")
        }
    }

    func test_onARotatedPageTheTextReadsUprightAsShown() throws {
        for rotate in [90, 180, 270] {
            let session = try EditKit.session("", "/Rotate \(rotate)")
            let shown = PageGeometry(session.document.pages[0])
            let box = shown.toUser(DisplayRect(100, 100, 200, 60))
            let result = try PageEditor(session, 0).addTextBox(box, "Upright text")
            XCTAssertTrue(result.done, "\(rotate): \(result.problem ?? "")")
            let glyphs = try EditKit.glyphs(session)
            XCTAssertEqual(glyphs.map { $0.text }.joined(), "Upright text", "\(rotate)")
            let points = glyphs.map { shown.toDisplay($0.x, $0.y) }
            for i in 1..<points.count {
                XCTAssertTrue(points[i].x > points[i - 1].x - 0.01, "\(rotate)")
                XCTAssertEqual(points[0].y, points[i].y, accuracy: 0.005, "\(rotate)")
            }
            XCTAssertTrue(points[0].x >= 99.9 && points[0].x <= 101, "\(rotate)")
        }
    }

    func test_aBoxWithNoAreaOrNoTextIsRefused() throws {
        let session = try EditKit.session("")
        let editor = try PageEditor(session, 0)
        XCTAssertFalse(try editor.addTextBox(PdfRect(10, 10, 10, 50), "x").done)
        XCTAssertFalse(try editor.addTextBox(PdfRect(10, 10, 50, 50), "").done)
        XCTAssertFalse(session.canUndo)
    }
}
