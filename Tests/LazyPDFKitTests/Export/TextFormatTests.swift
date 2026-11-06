import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/TextFormatTests.cs: the same cases. Text is counted in UTF-16 units, as the C#
// string lengths are.

final class TextFormatTests: XCTestCase {
    private func report() throws -> ExportDocument { try ExportLayout.analyze(ExportKit.report()) }

    private func turkish(_ text: String) -> ExportDocument {
        ExportDocument("Başlık", [ExportPage(0, 612, 792, [ExportParagraph(DisplayRect(72, 72, 400, 14), [ExportRun(text, false, false, 11)])], [], [])], 11)
    }

    private func item(_ text: String, _ level: Int) -> ExportParagraph {
        ExportParagraph(DisplayRect(Double(72 + 18 * level), 72, 100, 12), [ExportRun(text, false, false, 11)], 0, ExportListItem(1, false, level, 0))
    }

    private func count(_ text: String, _ part: String) -> Int {
        text.components(separatedBy: part).count - 1
    }

    private func balanced(_ rtf: String) -> Bool {
        var depth = 0
        var units = rtf.utf16.makeIterator()
        while let unit = units.next() {
            if unit == 0x5C {
                _ = units.next()
            } else if unit == 0x7B {
                depth += 1
            } else if unit == 0x7D {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    func test_reflowedHtmlIsSemanticAndSelfContained() throws {
        let html = try HtmlWriter.reflowed(report())
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<h1>Annual Report</h1>"))
        XCTAssertTrue(html.contains("<p>First line of the opening paragraph that runs on to a second line and stops there.</p>"))
        XCTAssertTrue(html.contains("<strong>important</strong>"))
        XCTAssertTrue(html.contains("<em>words.</em>"))
        XCTAssertTrue(html.contains("<ul>\n<li>Apples</li>\n<li>Pears</li>\n</ul>"))
        XCTAssertTrue(html.contains("<ol>\n<li>First step</li>\n<li>Second step</li>\n</ol>"))
        XCTAssertTrue(html.contains("<td>Tea</td><td>1,250.50</td>"))
        XCTAssertTrue(html.contains("<img src=\"data:image/jpeg;base64,/9j/"))
        XCTAssertFalse(html.contains("Confidential"))
        XCTAssertEqual(count(html, "<section "), 3)
        XCTAssertFalse(html.contains("src=\"http"))
        XCTAssertFalse(html.contains("<link"))
        for tag in ["ul", "ol", "table", "section", "li", "tr"] {
            XCTAssertEqual(count(html, "<\(tag)>") + count(html, "<\(tag) "), count(html, "</\(tag)>"), tag)
        }
    }

    func test_nestedListsNestInHtml() throws {
        let blocks: [ExportBlock] = [item("a", 0), item("b", 1), item("c", 1), item("d", 0)]
        let html = try HtmlWriter.reflowed(ExportDocument(nil, [ExportPage(0, 612, 792, blocks, [], [])], 11))
        XCTAssertTrue(html.contains("<ul>\n<li>a<ul>\n<li>b</li>\n<li>c</li>\n</ul>\n</li>\n<li>d</li>\n</ul>"))
    }

    func test_htmlEscapesAndKeepsTurkishLetters() throws {
        let html = try HtmlWriter.reflowed(turkish("Çağrı <b> & \"ğüşıİ\""))
        XCTAssertTrue(html.contains("<title>Başlık</title>"))
        XCTAssertTrue(html.contains("Çağrı &lt;b&gt; &amp; &quot;ğüşıİ&quot;"))
    }

    func test_fixedHtmlPlacesEveryLineAndHasNoPictures() throws {
        let report = try report()
        let html = try HtmlWriter.fixed(report)
        XCTAssertTrue(html.contains("class=\"page\""))
        XCTAssertTrue(html.contains("style=\"width:612pt;height:792pt\""))
        XCTAssertTrue(html.contains("left:72pt;top:"))
        XCTAssertTrue(html.contains("Confidential"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertEqual(count(html, "<span style=\"left:"), report.pages.reduce(0) { $0 + $1.lines.count })
        XCTAssertTrue(html.contains("font-weight:bold"))
        XCTAssertTrue(html.contains("font-style:italic"))
    }

    func test_rtfEscapesTurkishAsUnicodeAndKeepsTheStructure() throws {
        let rtf = try RtfWriter.make(turkish("ğ Ş ı İ {x} \\"))
        XCTAssertTrue(rtf.hasPrefix(#"{\rtf1\ansi"#))
        XCTAssertTrue(rtf.contains(#"\u287? \u350? \u305? \u304? \{x\} \\"#))
        XCTAssertTrue(rtf.contains(#"{\title Ba\u351?l\u305?k}"#))
        XCTAssertTrue(balanced(rtf))

        let report = try RtfWriter.make(self.report())
        XCTAssertTrue(balanced(report))
        XCTAssertTrue(report.contains(#"\trowd"#))
        XCTAssertTrue(report.contains(#"\pict\jpegblip"#))
        XCTAssertTrue(report.contains(ExportKit.jpeg.map { String(format: "%02x", $0) }.joined()))
        XCTAssertTrue(report.contains(#"\u8226?\tab "#))
        XCTAssertTrue(report.contains(#"1.\tab "#))
        XCTAssertEqual(count(report, #"\page"#), 2)
        XCTAssertFalse(report.contains("Confidential"))
    }

    func test_markdownHasHeadingsEmphasisListsAndTables() throws {
        let report = try report()
        let md = try MarkdownWriter.make(report)
        XCTAssertTrue(md.hasPrefix("# Annual Report\n\nFirst line"))
        XCTAssertTrue(md.contains("Second paragraph with **important** *words.*"))
        XCTAssertTrue(md.contains("- Apples\n- Pears\n\n1. First step\n2. Second step\n\n"))
        XCTAssertTrue(md.contains("| Item | Price |\n| --- | --- |\n| Tea | 1,250.50 |"))
        XCTAssertEqual(count(md, "\n---\n"), 2)
        XCTAssertFalse(md.contains("data:"))
        XCTAssertTrue(try MarkdownWriter.make(report, embedImages: true).contains("(data:image/jpeg;base64,"))
        XCTAssertTrue(md.hasSuffix("\n"))
    }

    func test_markdownEscapesWhatWouldBeSyntax() throws {
        let md = try MarkdownWriter.make(turkish("# not a heading *star* _under_ [link] a|b"))
        XCTAssertTrue(md.contains(##"\# not a heading \*star\* \_under\_ \[link\] a\|b"##))
        XCTAssertTrue(try MarkdownWriter.make(turkish("1. not a list")).contains("1\\. not a list"))
        XCTAssertTrue(try MarkdownWriter.make(turkish("ğüşıİ")).contains("ğüşıİ"))
    }

    func test_plainTextKeepsParagraphsListsAndTabbedCells() throws {
        let text = try PlainTextWriter.make(report())
        XCTAssertTrue(text.hasPrefix("Annual Report\n\nFirst line of the opening paragraph that runs on to a second line and stops there.\n\nSecond paragraph with important words.\n\n- Apples\n- Pears\n\n1. First step\n2. Second step\n\n"))
        XCTAssertTrue(text.contains("Item\tPrice\nTea\t1,250.50\n"))
        XCTAssertEqual(text.utf16.filter { $0 == 0x0C }.count, 3)
        XCTAssertFalse(text.contains("Confidential"))
    }

    func test_emptyDocumentsGiveEmptyOrMinimalText() throws {
        let empty = ExportDocument(nil, [], 11)
        XCTAssertEqual(try PlainTextWriter.make(empty), "")
        XCTAssertEqual(try MarkdownWriter.make(empty), "")
        XCTAssertTrue(balanced(try RtfWriter.make(empty)))
        XCTAssertTrue(try HtmlWriter.reflowed(empty).contains("<body>"))
        XCTAssertTrue(try HtmlWriter.fixed(empty).contains("<body>"))
    }
}
