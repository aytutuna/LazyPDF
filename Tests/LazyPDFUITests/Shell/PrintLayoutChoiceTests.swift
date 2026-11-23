#if canImport(SwiftUI)
import XCTest
import LazyPDFApp
@testable import LazyPDFUI

@MainActor
final class PrintLayoutChoiceTests: XCTestCase {
    func test_theBindingComesFromTheDocumentNotFromTheRememberedLayout() {
        let remembered = PrintLayout(booklet: true, rightToLeft: true)

        XCTAssertFalse(PrintLayoutChoice(remembered: remembered, rightToLeft: false, documentPages: 8).layout.rightToLeft)
        XCTAssertTrue(PrintLayoutChoice(remembered: PrintLayout(booklet: true), rightToLeft: true, documentPages: 8).layout.rightToLeft)
    }

    func test_aWrongRangeStopsPrinting() {
        let choice = PrintLayoutChoice(remembered: PrintLayout(range: "9-12"), documentPages: 8)

        XCTAssertNotNil(choice.problem)
        XCTAssertFalse(choice.canPrint)
    }

    func test_evenSidesOfOneSideLeaveNothingToPrint() {
        let choice = PrintLayoutChoice(remembered: PrintLayout(perSheet: 2, parity: .even), documentPages: 2)

        XCTAssertNil(choice.problem)
        XCTAssertFalse(choice.canPrint)
    }

    func test_aGoodLayoutCanPrint() {
        XCTAssertTrue(PrintLayoutChoice(remembered: PrintLayout(booklet: true), documentPages: 8).canPrint)
    }
}
#endif
