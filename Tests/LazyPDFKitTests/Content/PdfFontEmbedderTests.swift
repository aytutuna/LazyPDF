import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/PdfFontEmbedderTests.cs: the same cases. The C# source reads Arial from
// the Windows fonts folder; here it hands out the synthetic font of the font program tests, which has A, B, space,
// ğ, ı, İ and À, so the texts use those letters (and 中 for the missing one) where the C# uses Turkish prose. A
// C# assertion that PdfPig reads the text back has no twin; the rest of those tests stay.

final class PdfFontEmbedderTests: XCTestCase {
    private final class FixtureFonts: FontSource {
        var requests: [(family: String, style: FontStyles)] = []
        private let data: [UInt8]

        init() throws {
            data = try SyntheticFonts.ttf()
        }

        func find(_ family: String, _ style: FontStyles) -> FontFile? {
            requests.append((family, style))
            return FontFile(data)
        }
    }

    private final class NoFonts: FontSource {
        func find(_ family: String, _ style: FontStyles) -> FontFile? { nil }
    }

    private final class JunkFonts: FontSource {
        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile([1, 2, 3, 4, 5, 6, 7, 8]) }
    }

    private let turkish = "AB ğİ BA"

    private func blank() throws -> PdfDocument { try PdfDocument.open(TestPdf.simple(1)) }

    private func draw(_ document: PdfDocument, _ font: PdfDrawFont, _ text: String, _ size: Double) throws -> [UInt8] {
        let page = document.pages[0]
        let resources = ContentResources.forEdit(document, page)
        let name = ContentResources.add(document, resources, "Font", font.reference, "F")
        let content = ContentWriter().beginText().font(name, size).moveText(50, 700).show(font.encode(text)).endText()
        let stream = PdfStream(PdfDictionary(), data: content.toArray())
        page.dictionary["Contents"] = try document.add(stream)
        return try document.saveRewrite()
    }

    func test_winAnsiTextUsesAStandardFont() throws {
        let document = try blank()
        let font = try XCTUnwrap(try PdfFontEmbedder(document).add("Helvetica", .regular, ["Hello, World (café)"]))
        XCTAssertFalse(font.isEmbedded)
        let dictionary = try XCTUnwrap(document.resolve(font.reference) as? PdfDictionary)
        XCTAssertEqual((dictionary["BaseFont"] as? PdfName)?.value, "Helvetica")
        XCTAssertEqual((dictionary["Encoding"] as? PdfName)?.value, "WinAnsiEncoding")
        XCTAssertEqual(font.encode("é")[0], 0xE9)
        XCTAssertEqual(font.width("Hello", 10), Double((722 + 556 + 222 + 222 + 556) * 10) / 1000.0, accuracy: 5e-7)
    }

    func test_arialAndStyleMapToTheStandardNames() throws {
        let document = try blank()
        let embedder = PdfFontEmbedder(document)
        func base(_ family: String, _ style: FontStyles) throws -> String? {
            let f = try XCTUnwrap(try embedder.add(family, style, ["x"]))
            return ((document.resolve(f.reference) as? PdfDictionary)?["BaseFont"] as? PdfName)?.value
        }
        XCTAssertEqual(try base("Arial", .bold), "Helvetica-Bold")
        XCTAssertEqual(try base("Helvetica", [.bold, .italic]), "Helvetica-BoldOblique")
        XCTAssertEqual(try base("Times New Roman", .italic), "Times-Italic")
        XCTAssertEqual(try base("Courier New", .regular), "Courier")
    }

    func test_turkishTextNeedsAFontFile() throws {
        let document = try blank()
        XCTAssertNil(try PdfFontEmbedder(document).add("Arial", .regular, [turkish]))
        XCTAssertNil(try PdfFontEmbedder(document, NoFonts()).add("Arial", .regular, [turkish]))
        XCTAssertNil(try PdfFontEmbedder(document, NoFonts()).add("Whatever", .regular, ["abc"]))
    }

    func test_turkishTextIsEmbeddedAndReadBackByPdfPigAndUs() throws {
        let document = try blank()
        let source = try FixtureFonts()
        let font = try XCTUnwrap(try PdfFontEmbedder(document, source).add("Arial", .regular, [turkish]))
        XCTAssertTrue(font.isEmbedded)
        XCTAssertTrue(font.missing.isEmpty)
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertEqual(source.requests[0].family, "Arial")
        XCTAssertEqual(source.requests[0].style, .regular)

        let file = try draw(document, font, turkish, 14)

        let reopened = try PdfDocument.open(file)
        let fonts = try XCTUnwrap(reopened.dict(reopened.pages[0].resources, "Font"))
        let dictionary = try XCTUnwrap(reopened.resolve(fonts.entries[0].value) as? PdfDictionary)
        let ours = PdfFont.get(reopened, dictionary)
        XCTAssertTrue(ours.isComposite)
        XCTAssertEqual(ours.toText(font.encode(turkish)), turkish)
        let recorder = ContentTestPdf.run(reopened)
        XCTAssertEqual(recorder.text, turkish)
    }

    func test_theEmbeddedFontIsASubsetWithTheUsualPieces() throws {
        let document = try blank()
        let font = try XCTUnwrap(try PdfFontEmbedder(document, try FixtureFonts()).add("Arial", .regular, ["ğİ"], embed: true))
        let type0 = try XCTUnwrap(document.resolve(font.reference) as? PdfDictionary)
        XCTAssertEqual((type0["Subtype"] as? PdfName)?.value, "Type0")
        XCTAssertEqual((type0["Encoding"] as? PdfName)?.value, "Identity-H")
        XCTAssertTrue(document.resolve(type0["ToUnicode"]) is PdfStream)
        let descendants = try XCTUnwrap(document.resolve(type0["DescendantFonts"]) as? PdfArray)
        let cid = try XCTUnwrap(document.resolve(descendants.items[0]) as? PdfDictionary)
        XCTAssertEqual((cid["Subtype"] as? PdfName)?.value, "CIDFontType2")
        XCTAssertTrue(document.resolve(cid["W"]) is PdfArray)
        let descriptor = try XCTUnwrap(document.resolve(cid["FontDescriptor"]) as? PdfDictionary)
        let program = try XCTUnwrap(document.resolve(descriptor["FontFile2"]) as? PdfStream)
        XCTAssertLessThan(try document.data(program).count, try SyntheticFonts.ttf().count)
        let baseFont = try XCTUnwrap((type0["BaseFont"] as? PdfName)?.value)
        XCTAssertNotNil(baseFont.range(of: "^[A-Z]{6}\\+", options: .regularExpression), baseFont)
    }

    func test_incrementalSaveReopensToo() throws {
        let document = try blank()
        let font = try XCTUnwrap(try PdfFontEmbedder(document, try FixtureFonts()).add("Arial", .bold, ["İ ğAB"]))
        let page = document.pages[0]
        let resources = ContentResources.forEdit(document, page)
        let name = ContentResources.add(document, resources, "Font", font.reference, "F")
        let content = ContentWriter().beginText().font(name, 12).moveText(10, 10).show(font.encode("İ ğAB")).endText()
        page.dictionary["Contents"] = try document.add(PdfStream(PdfDictionary(), data: content.toArray()))
        let file = try document.saveIncremental()
        let reopened = try PdfDocument.open(file)
        XCTAssertTrue(reopened.repairs.isEmpty)
        XCTAssertEqual(ContentTestPdf.run(reopened).text, "İ ğAB")
    }

    func test_charactersTheFontLacksAreListed() throws {
        let document = try blank()
        let font = try XCTUnwrap(try PdfFontEmbedder(document, try FixtureFonts()).add("Arial", .regular, ["A中B"], embed: true))
        XCTAssertEqual(font.missing, [0x4E2D])
    }

    func test_eachCallAddsItsOwnFont() throws {
        let document = try blank()
        let embedder = PdfFontEmbedder(document, try FixtureFonts())
        let a = try XCTUnwrap(try embedder.add("Arial", .regular, ["AB"], embed: true))
        let b = try XCTUnwrap(try embedder.add("Arial", .regular, ["AB ğ"], embed: true))
        XCTAssertNotEqual(a.reference, b.reference)
    }

    func test_notAFontFileGivesNull() throws {
        let document = try blank()
        XCTAssertNil(try PdfFontEmbedder(document, JunkFonts()).add("X", .regular, ["ğ"]))
    }

    func test_widthOfEmbeddedTextMatchesTheFontProgram() throws {
        let document = try blank()
        let font = try XCTUnwrap(try PdfFontEmbedder(document, try FixtureFonts()).add("Arial", .regular, ["AB"], embed: true))
        // The synthetic font: A 600, B 550 of 1000.
        XCTAssertEqual(font.width("AB", 10), Double(600 + 550) / 1000.0 * 10, accuracy: 5e-3)
        XCTAssertEqual(font.width("", 10), 0)
    }

    func test_wrapBreaksAtSpacesNewlinesAndLongWords() throws {
        let document = try blank()
        let font = try XCTUnwrap(try PdfFontEmbedder(document).add("Courier", .regular, ["x"]))
        // Courier is 600 wide: at size 10 a character is 6 points.
        XCTAssertEqual(font.wrap("aaa bbb ccc", 10, 45), ["aaa bbb", "ccc"])
        XCTAssertEqual(font.wrap("ab\ncd", 10, 1000), ["ab", "cd"])
        XCTAssertEqual(font.wrap("abcdefghij", 10, 25), ["abcd", "efgh", "ij"])
        XCTAssertEqual(font.wrap("", 10, 100), [""])
        XCTAssertEqual(font.wrap("a\n\nb", 10, 100), ["a", "", "b"])
        for line in font.wrap("the quick brown fox jumps over the lazy dog", 10, 100) {
            XCTAssertLessThanOrEqual(font.width(line, 10), 100, line)
        }
    }

    func test_lineHeightFollowsTheMetrics() throws {
        let document = try blank()
        let font = try XCTUnwrap(try PdfFontEmbedder(document).add("Helvetica", .regular, ["x"]))
        XCTAssertTrue(font.lineHeight(10) > 10 && font.lineHeight(10) < 20)
        XCTAssertTrue(font.ascent > 0 && font.descent < 0)
    }

    func test_noBreakSpaceAndSoftHyphenFitWinAnsi() throws {
        let document = try blank()
        XCTAssertNotNil(try PdfFontEmbedder(document, NoFonts()).add("Helvetica", .regular, ["10\u{A0}km \u{AD}x"]))
    }
}
