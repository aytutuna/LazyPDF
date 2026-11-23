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
        // A run that left the second file unsaved makes the next launch ask to restore it.
        let discard = app.buttons["Discard"].firstMatch
        if discard.waitForExistence(timeout: 5) { discard.tap() }
        return app
    }

    @MainActor
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func drag(_ from: XCUIElement, to end: XCUICoordinate) {
        let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
    }

    private func drag(_ from: XCUIElement, to target: XCUIElement) {
        drag(from, to: target.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
    }

    // The slot after the last tab: a tab's own close button ends about 24 points before it.
    private func endOfStrip(_ last: XCUIElement) -> XCUICoordinate {
        last.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: last.frame.width + 36, dy: last.frame.height / 2))
    }

    // A copy or an extract leaves a file unsaved; closing it without saving leaves nothing for the next launch to restore.
    @MainActor
    private func closeWithoutSaving(_ app: XCUIApplication, _ tab: XCUIElement) {
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close'")).allElementsBoundByIndex
            .min { abs($0.frame.midX - tab.frame.maxX) < abs($1.frame.midX - tab.frame.maxX) }
        close?.tap()
        let dontSave = app.buttons["Don't save"].firstMatch
        if dontSave.waitForExistence(timeout: 5) { dontSave.tap() }
    }

    // Opens the page grid of the first file.
    @MainActor
    private func organize(_ app: XCUIApplication) -> XCUIElement {
        tab(app, "text-pages").tap()
        let group = app.buttons["Organize"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        group.tap()
        let row = app.buttons["Organize pages"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Page 1'")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30))
        return page
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
    func testDraggingATabPastTheLastOneMovesItToTheEnd() throws {
        let app = try launch()
        let text = tab(app, "text-pages")
        let plain = tab(app, "plain-3")
        XCTAssertTrue(text.waitForExistence(timeout: 60))
        XCTAssertTrue(plain.waitForExistence(timeout: 60))

        drag(text, to: endOfStrip(plain))

        let moved = NSPredicate { _, _ in plain.frame.minX < text.frame.minX }
        wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 10)
    }

    @MainActor
    func testDroppingAPageOnATabCopiesIt() throws {
        let app = try launch()
        let plain = tab(app, "plain-3")
        XCTAssertTrue(plain.waitForExistence(timeout: 60))
        let page = organize(app)

        drag(page, to: plain)

        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Copied 1 page to'")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))

        closeWithoutSaving(app, plain)
    }

    // The slot after the last tab is a part of the strip: pages let go there make a new file.
    @MainActor
    func testDroppingAPagePastTheLastTabMakesANewTab() throws {
        let app = try launch()
        let plain = tab(app, "plain-3")
        XCTAssertTrue(plain.waitForExistence(timeout: 60))
        let page = organize(app)

        drag(page, to: endOfStrip(plain))

        let made = tab(app, "extract")
        XCTAssertTrue(made.waitForExistence(timeout: 20))
        closeWithoutSaving(app, made)
    }
}
