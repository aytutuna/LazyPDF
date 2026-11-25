import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testAppOpensAWindow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60))
    }
}
