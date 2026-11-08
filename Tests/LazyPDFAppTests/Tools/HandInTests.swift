import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// The window's side of ToolPanel.HandIn (windows/LazyPDF.App/MainWindow.xaml.cs, HandInTyping): closing and exiting ask the open
// tool to put what is typed into the file first, and wait when it says it has not. Save and Undo ask through FileActions.

@MainActor
final class HandInTests: XCTestCase {
    func test_closingTheShownDocumentAsksTheToolFirstAndWaitsWhenItIsNotDone() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = try XCTUnwrap(f.vm.activeDocument)
        var asked = 0
        f.vm.handInTyping = {
            asked += 1
            return false
        }

        XCTAssertFalse(f.vm.requestClose(tab))

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertNil(f.vm.closeQuestion)
    }

    func test_closingGoesOnWhenTheToolHandedItsTextIn() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = try XCTUnwrap(f.vm.activeDocument)
        f.vm.handInTyping = { true }

        XCTAssertTrue(f.vm.requestClose(tab))

        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    func test_aDocumentThatIsNotShownIsClosedWithoutAskingTheTool() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf("a.pdf"))
        let first = try XCTUnwrap(f.vm.activeDocument)
        await f.vm.open(f.pdf("b.pdf"))
        var asked = 0
        f.vm.handInTyping = {
            asked += 1
            return false
        }

        XCTAssertTrue(f.vm.requestClose(first))

        XCTAssertEqual(asked, 0)
    }

    func test_exitingAsksTheToolAndWaitsWhenItIsNotDone() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        var asked = 0
        f.vm.handInTyping = {
            asked += 1
            return false
        }

        XCTAssertFalse(f.vm.requestExit())

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(f.vm.documents.count, 1)
    }

    func test_withNoToolOpenThereIsNothingToHandIn() {
        let f = ViewModelFixture(self)

        XCTAssertTrue(f.vm.handIn())
    }
}
