import XCTest
@testable import LazyPDFApp

@MainActor
final class SelectionMarkTests: XCTestCase {
    func test_aMarkOpensItsToolAndWaitsForItToAttach() {
        let f = ViewModelFixture(self)

        f.vm.markSelection(.redact)

        XCTAssertEqual(f.vm.activeToolId, "redact")
        XCTAssertEqual(f.vm.takeSelectionMark(), .redact)
        XCTAssertNil(f.vm.takeSelectionMark())
    }

    func test_highlightGoesToTheCommentTool() {
        let f = ViewModelFixture(self)

        f.vm.markSelection(.highlight)

        XCTAssertEqual(f.vm.activeToolId, "comment")
    }

    func test_anOpenToolGetsTheMarkAtOnceAndStaysOpen() async {
        let f = ViewModelFixture(self)
        f.vm.selectTool("comment")
        var got: [SelectionMark] = []
        f.vm.takesSelectionMarks { got.append($0) }

        f.vm.markSelection(.note)
        await Task.yield()

        XCTAssertEqual(got, [.note])
        XCTAssertEqual(f.vm.activeToolId, "comment")
        XCTAssertNil(f.vm.takeSelectionMark())
    }
}
