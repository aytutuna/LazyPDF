import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/RichTextTests.cs: the same cases. The XML reader of the Structure layer
// refuses nesting deeper than 1000 levels where XmlReader has no limit, so DeepNestingDoesNotOverflow nests 900 spans and
// then checks that 5000 give no text instead of "x".

final class RichTextTests: XCTestCase {
    private let open = "<body xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:xfa=\"http://www.xfa.org/schema/xfa-data/1.0/\" xfa:APIVersion=\"Acrobat:11.0.0\" style=\"font-size:11pt;font-family:Arial;color:#000000\">"

    func test_plainTextKeepsParagraphsOnLines() {
        XCTAssertEqual(PdfRichText.toPlain(open + "<p dir=\"ltr\"><span>one</span></p><p>two</p></body>"), "one\ntwo")
        XCTAssertEqual(PdfRichText.toPlain(open + "<p>a<br/>b</p></body>"), "a\nb")
        XCTAssertEqual(PdfRichText.toPlain(open + "<p>a  \n  b <b>c</b></p></body>"), "a b c")
    }

    func test_indentationBetweenBlocksIsNotText() {
        XCTAssertEqual(PdfRichText.toPlain("<body xmlns=\"http://www.w3.org/1999/xhtml\">\n  <p>one</p>\n  <p>two</p>\n</body>"), "one\ntwo")
    }

    func test_entitiesAndTurkishLettersAreText() {
        XCTAssertEqual(PdfRichText.toPlain("<body xmlns=\"http://www.w3.org/1999/xhtml\"><p>a &amp; b &lt; &#351;</p></body>"), "a & b < ş")
    }

    func test_brokenMarkupGivesNoText() {
        for xhtml in ["", "<body><p>unclosed", "<!DOCTYPE b [<!ENTITY x \"y\">]><body>&x;</body>"] {
            XCTAssertEqual(PdfRichText.toPlain(xhtml), "", xhtml)
        }
    }

    func test_textWithoutMarkupIsItself() {
        XCTAssertEqual(PdfRichText.toPlain("just words"), "just words")
    }

    func test_hugeInputIsRefused() {
        XCTAssertEqual(PdfRichText.toPlain("<body>" + String(repeating: "x", count: 300_000) + "</body>"), "")
    }

    func test_deepNestingDoesNotOverflow() {
        func nested(_ levels: Int) -> String {
            "<body>" + String(repeating: "<span>", count: levels) + "x" + String(repeating: "</span>", count: levels) + "</body>"
        }
        XCTAssertEqual(PdfRichText.toPlain(nested(900)), "x")
        XCTAssertEqual(PdfRichText.toPlain(nested(5000)), "")
    }

    func test_aLeadingXmlDeclarationIsAllowed() {
        XCTAssertEqual(PdfRichText.toPlain("<?xml version=\"1.0\"?><body xmlns=\"http://www.w3.org/1999/xhtml\"><p>hello</p></body>"), "hello")
        XCTAssertEqual(PdfRichText.toPlain(" <?xml version=\"1.0\"?><p>late</p>"), "")
        XCTAssertEqual(PdfRichText.toPlain("<?xml?><p>bad</p>"), "")
    }
}
