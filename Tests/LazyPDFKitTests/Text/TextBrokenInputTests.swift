import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextBrokenInputTests.cs: the same cases. The random content comes from a
// generator of its own (System.Random has no Swift twin), so the 150 pages are not the C# ones.

final class TextBrokenInputTests: TextTestCase {
    private struct Random {
        private var state: UInt64

        init(_ seed: UInt64) { state = seed }

        mutating func nextBits() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }

        /// 0 up to, not including, `limit`.
        mutating func next(_ limit: Int) -> Int { Int(nextBits() % UInt64(limit)) }

        mutating func next(_ low: Int, _ high: Int) -> Int { low + next(high - low) }

        mutating func nextDouble() -> Double { Double(nextBits()) / Double(1 << 31) }
    }

    private func number(_ random: inout Random) -> String {
        let v: Double
        switch random.next(8) {
        case 0: v = 0
        case 1: v = random.nextDouble() * 1e9
        case 2: v = -random.nextDouble() * 1e6
        case 3: v = random.nextDouble() * 1e-6
        default: v = random.nextDouble() * 800 - 100
        }
        var text = String(format: "%.6f", v)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private func randomContent(_ random: inout Random) -> String {
        var sb = "BT /F1 10 Tf "
        let ops = ["Td", "TD", "Tm", "Tf", "Tc", "Tw", "Tz", "TL", "Ts", "Tr", "T*", "cm", "q", "Q", "BT", "ET"]
        let count = random.next(5, 120)
        for _ in 0..<count {
            switch random.next(4) {
            case 0:
                let letters = (0..<random.next(1, 12)).map { _ in Character(Unicode.Scalar(UInt8(random.next(65, 123)))) }
                sb += "(" + String(letters) + ") Tj "
            case 1:
                sb += "[(ab) \(number(&random)) (cd)] TJ "
            default:
                let op = ops[random.next(ops.count)]
                let operands: Int
                switch op {
                case "Tm", "cm": operands = 6
                case "Td", "TD": operands = 2
                case "T*", "q", "Q", "BT", "ET": operands = 0
                case "Tf": operands = 0
                default: operands = 1
                }
                for _ in 0..<operands { sb += number(&random) + " " }
                sb += op == "Tf" ? "/F1 " + number(&random) + " Tf " : op + " "
            }
        }
        return sb
    }

    func test_randomContentNeverBreaksThePage() throws {
        var random = Random(11)
        for _ in 0..<150 {
            let document = try self.page(randomContent(&random))
            let page = TextPage.create(document, document.pages[0])
            XCTAssertNil(TextInvariants.check(page))
            _ = try TextSearch.find(page, "ab")
            _ = TextSelection.between(page, 10, 10, 500, 700).getText()
            _ = TextSelection.inRectangle(page, PdfRect(0, 0, 600, 800)).quads()
            _ = page.hitTest(300, 400)
        }
    }

    func test_aDegenerateMatrixLeavesNothingBehind() throws {
        let page = try text("BT /F1 10 Tf 0 0 0 0 100 100 Tm (flat) Tj ET BT /F1 1000000000000 Tf 1 0 0 1 0 0 Tm (huge) Tj ET")
        XCTAssertNil(TextInvariants.check(page))
    }

    func test_aFormThatDrawsItselfIsRunOnce() throws {
        let document = try page("/Fm Do", "/Font <</F1 5 0 R>> /XObject <</Fm 7 0 R>>", "") { pdf in
            self.font(pdf, 5)
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</Fm 7 0 R>>>>", "/Fm Do " + self.line(100, 700, "loop"))
        }
        XCTAssertEqual(TextPage.create(document, document.pages[0]).text, "loop")
    }

    func test_aBrokenFontDictionaryStillGivesGlyphBoxes() throws {
        let document = try self.page("BT /F1 10 Tf 100 700 Td (abc) Tj ET", "/Font <</F1 5 0 R>>", "") { pdf in
            pdf.obj(5, "<</Type /Font /Subtype /Type0 /DescendantFonts [<<>>]>>")
        }
        let page = TextPage.create(document, document.pages[0])
        XCTAssertNil(TextInvariants.check(page))
    }

    func test_extraArgumentsAreHandled() throws {
        let document = try self.page(line(100, 700, "abc"))
        let page = TextPage.create(document, document.pages[0])
        XCTAssertEqual(TextSelection.of(page, TextRange(-5, 99)).ranges[0], TextRange(0, 3))
        XCTAssertEqual(page.getText(TextRange(9, 3)), "")
        XCTAssertTrue(page.quads(TextRange(5, 1)).isEmpty)
        XCTAssertTrue(try TextSearch.find(page, "zzz").isEmpty)
    }

    func test_extremePositionsAreClamped() throws {
        let document = try self.page(line(100, 700, "abc"))
        let page = TextPage.create(document, document.pages[0])
        let all = TextRange(Int.min, Int.max)
        XCTAssertEqual(all.count, 0)
        XCTAssertEqual(page.getText(all), "abc")
        XCTAssertEqual(page.quads(all).count, 1)
        XCTAssertEqual(TextSelection.of(page, all).ranges, [TextRange(0, 3)])
        for range in [TextRange(Int.max, Int.min), TextRange(-1, -1), TextRange(Int.max, Int.max), TextRange(Int.min, Int.min), TextRange(-1, Int.max)] {
            _ = range.count
            _ = page.getText(range)
            _ = page.quads(range)
            _ = TextSelection.of(page, range).getText()
        }
        XCTAssertEqual(page.getText(TextRange(Int.max, Int.min)), "")
        XCTAssertEqual(page.getText(TextRange(-1, Int.max)), "abc")
        XCTAssertTrue(TextSelection.of(page, TextRange(Int.max, Int.min)).ranges.isEmpty)
    }
}
