import XCTest

// iPad only: the tab strip is not there in the compact layout. The strip's two drops, a tab id (reorder) and a page (copy),
// are on the same views, so both are run with a real drag.
final class TabDragTests: XCTestCase {
    @MainActor
    private func launch() throws -> XCUIApplication {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "The tab strip is iPad only")
        let bundle = Bundle(for: TabDragTests.self)
        let first = try XCTUnwrap(bundle.url(forResource: "text-pages", withExtension: "pdf"))
        let second = try XCTUnwrap(bundle.url(forResource: "plain-3", withExtension: "pdf"))
        let app = XCUIApplication()
        app.launchArguments = ["-uitestOpen", first.path, "-uitestOpenNext", second.path]
        app.launch()
        return app
    }

    @MainActor
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func drag(_ from: XCUIElement, to target: XCUIElement) {
        let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
    }

    @MainActor
    func testDraggingATabReordersTheStrip() throws {
        let app = try launch()
        let text = tab(app, "text-pages")
        let plain = tab(app, "plain-3")
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        XCTAssertTrue(plain.waitForExistence(timeout: 60))
        XCTAssertLessThan(text.frame.minX, plain.frame.minX)

        drag(plain, to: text)

        let moved = NSPredicate { _, _ in plain.frame.minX < text.frame.minX }
        wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 10)
    }

    @MainActor
    func testDroppingAPageOnATabCopiesIt() throws {
        let app = try launch()
        let text = tab(app, "text-pages")
        let plain = tab(app, "plain-3")
        XCTAssertTrue(plain.waitForExistence(timeout: 60))
        text.tap()

        let tools = app.buttons["Tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10))
        tools.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Organize pages")
        let row = app.buttons["Organize pages"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let page = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Page 1'")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30))
        drag(page, to: plain)

        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Copied 1 page to'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
    }
}
