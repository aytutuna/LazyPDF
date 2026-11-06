import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/PageTintTests.cs: the tint is on the pixels shown, never on the file.

final class PageTintTests: XCTestCase {
    private func one(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [r, g, b, 255] }

    func test_noTintOnlyReordersTheChannels() {
        XCTAssertEqual(PageTints.toBgra(one(10, 20, 30), .none), [30, 20, 10, 255])
    }

    func test_darkMakesWhitePaperDarkAndBlackInkLight() {
        let white = PageTints.toBgra(one(255, 255, 255), .dark)
        let black = PageTints.toBgra(one(0, 0, 0), .dark)

        XCTAssertTrue((20...60).contains(white[0]))
        XCTAssertTrue((200...240).contains(black[0]))
        XCTAssertTrue((20...60).contains(white[1]))
        XCTAssertTrue((20...60).contains(white[2]))
    }

    func test_darkKeepsAColourItsHue() {
        let red = PageTints.toBgra(one(220, 30, 30), .dark)

        XCTAssertTrue(red[2] > red[1] && red[2] > red[0])
    }

    func test_sepiaMakesWhitePaperThePaperColourAndBlackStaysBlack() {
        let paper = PageTints.toBgra(one(255, 255, 255), .sepia)
        let ink = PageTints.toBgra(one(0, 0, 0), .sepia)

        XCTAssertEqual(paper, [216, 236, 244, 255])
        XCTAssertEqual(ink, [0, 0, 0, 255])
    }

    func test_aTileBecomesABitmapOfTheSameSize() {
        let bitmap = TileBitmap(PdfRgbaImage(3, 2, [UInt8](repeating: 0, count: 3 * 2 * 4)), .none)

        XCTAssertEqual([bitmap.pixelWidth, bitmap.pixelHeight], [3, 2])
        XCTAssertEqual(bitmap.bgra.count, 3 * 2 * 4)
    }

    func test_thePaperBeforeThePicturesArriveMatchesTheTint() {
        XCTAssertEqual(PageTints.paper(.none), PaperColor(red: 255, green: 255, blue: 255))
        XCTAssertEqual(PageTints.paper(.dark), PaperColor(red: 0x1C, green: 0x1C, blue: 0x1C))
        XCTAssertEqual(PageTints.paper(.sepia), PaperColor(red: 0xF4, green: 0xEC, blue: 0xD8))
    }
}
