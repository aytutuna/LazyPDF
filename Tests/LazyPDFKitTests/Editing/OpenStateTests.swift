import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/OpenStateTests.cs: the same cases. What the edit did not select has to
// look as it did, whatever state the content leaves open. The theory is one test that loops over the pages.

final class OpenStateTests: XCTestCase {
    private let pages = [
        "q 0 0 600 800 re W n 1 0 0 rg BT /F1 12 Tf 50 700 Td (one two three) Tj ET Q",
        "q q q 1 0 0 1 20 -30 cm BT /F1 12 Tf 30 730 Td (one two three) Tj ET Q",
        "2 0 0 2 0 0 cm BT /F1 6 Tf 25 350 Td (one two three) Tj ET",
        "BT /F1 12 Tf 50 700 Td 0.3 Tc 2 Tw 110 Tz 4 Ts (one two three) Tj",
        "BT /F1 12 Tf 14 TL 50 700 Td (one) Tj T* (two three) Tj (more) ' ET",
        "/Span <</MCID 0>> BDC BT /F1 12 Tf 50 700 Td [(one t) -30 (wo three)] TJ ET EMC",
        "BT /F1 12 Tf 1 0 0 1 50 700 Tm (one) Tj 100 0 Td (two) Tj 0 -14 Td (three) Tj ET",
    ]

    func test_untouchedGlyphsStayWhereTheyWere() throws {
        for content in pages {
            let tail = "\n0 0 1 rg 10 10 20 20 re f 0 g BT /F1 10 Tf 200 100 Td (after) Tj ET"
            let session = try EditKit.session(content + tail)
            let before = try EditKit.glyphs(session)
            let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "two"), "2x2")
            XCTAssertTrue(result.done, "\(content): \(result.problem ?? "")")
            let after = try EditKit.glyphs(session)
            let beforeText = before.map { $0.text }.joined()
            XCTAssertEqual(beforeText.replacingOccurrences(of: "two", with: "2x2"), after.map { $0.text }.joined(), content)
            // The text before the word, and everything drawn after the edited operator, is where it was.
            let at = beforeText.distance(from: beforeText.startIndex, to: try XCTUnwrap(beforeText.range(of: "two", options: .literal)).lowerBound)
            XCTAssertEqual(Array(before.prefix(at)), Array(after.prefix(at)), content)
            XCTAssertEqual(Array(before.suffix(5)), Array(after.suffix(5)), content)
            let text = EditKit.latin(session)
            XCTAssertTrue(text.hasSuffix(tail), content)
            let head = String(content[..<(try XCTUnwrap(content.range(of: "(one", options: .literal)).lowerBound)])
            XCTAssertTrue(text.hasPrefix(head), content)
        }
    }

    func test_theStateAfterTheEditedRunIsTheOneBefore() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td 0.4 Tc (one two three) Tj ET")
        _ = try PageEditor(session, 0).setTextStyle([try EditKit.find(session, "two")], TextStyleChange(size: 20, color: RgbColor(255, 0, 0), charSpacing: 1))
        let document = try PdfDocument.open(session.current)
        let probe = Probe()
        ContentInterpreter(document).run(document.pages[0], probe)
        let seen = probe.seen
        let w = try XCTUnwrap(seen.first { $0.text == "w" })
        XCTAssertEqual(w.size, 20)
        XCTAssertEqual(w.spacing, 1)
        XCTAssertEqual(w.color, RgbColor(255, 0, 0))
        // "three" is back to the original size, spacing and colour.
        let wAt = try XCTUnwrap(seen.firstIndex { $0.text == "w" })
        let three = try XCTUnwrap(seen.dropFirst(wAt + 2).first { $0.text == "t" })
        XCTAssertEqual(three.size, 12)
        XCTAssertEqual(three.spacing, 0.4)
        XCTAssertEqual(three.color, RgbColor(0, 0, 0))
    }

    private final class Probe: ContentVisitor {
        var seen: [(text: String, size: Double, spacing: Double, color: RgbColor)] = []

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            seen.append((glyph.unicode ?? "", context.state.fontSize, context.state.charSpacing, context.state.fillColor.rgb))
        }
    }
}
