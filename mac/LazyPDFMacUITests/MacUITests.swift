import XCTest

final class MacUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // The app is sandboxed and cannot read the test bundle, so the file travels in the launch arguments (MacShell.openTestFile).
    private func launch(opening fixture: Bool) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        if fixture {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "plain-3", withExtension: "pdf"))
            let data = try Data(contentsOf: url)
            app.launchArguments += ["-LazyPDFTestFile", "plain-3.pdf", "-LazyPDFTestData", data.base64EncodedString()]
        }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any)[label].firstMatch
    }

    private func choose(_ app: XCUIApplication, menu: String, item: String) {
        app.menuBars.menuBarItems[menu].click()
        app.menuBars.menuItems[item].click()
    }

    private func tab(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews["Open files"].buttons["plain-3.pdf"]
    }

    func testLaunchShowsHome() throws {
        let app = try launch(opening: false)

        XCTAssertTrue(element(app, "What would you like to do?").waitForExistence(timeout: 30))
    }

    func testOpeningAFileShowsItsTabAndFirstPage() throws {
        let app = try launch(opening: true)

        XCTAssertTrue(tab(app).waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "Page 1 of 3").waitForExistence(timeout: 30))
    }

    func testFindShowsTheMatchCount() throws {
        let app = try launch(opening: true)
        XCTAssertTrue(element(app, "Page 1 of 3").waitForExistence(timeout: 30))

        choose(app, menu: "Edit", item: "Find")
        let field = app.textFields["Search text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("Page 2")

        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 20))
    }

    func testZoomInChangesTheZoomLabel() throws {
        let app = try launch(opening: true)
        let zoom = element(app, "Zoom")
        XCTAssertTrue(zoom.waitForExistence(timeout: 30))
        let before = zoom.value as? String

        choose(app, menu: "View", item: "Zoom in")

        let changed = NSPredicate { _, _ in (zoom.value as? String) != before }
        wait(for: [expectation(for: changed, evaluatedWith: nil)], timeout: 10)
    }

    func testCloseTabReturnsToHome() throws {
        let app = try launch(opening: true)
        XCTAssertTrue(element(app, "Page 1 of 3").waitForExistence(timeout: 30))
        XCTAssertTrue(tab(app).exists)

        choose(app, menu: "File", item: "Close")

        XCTAssertTrue(element(app, "What would you like to do?").waitForExistence(timeout: 10))
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: tab(app))], timeout: 10)
        wait(for: [expectation(for: gone, evaluatedWith: element(app, "Page 1 of 3"))], timeout: 10)
    }

    // The sandbox lets the app touch the file it opened but not its folder, so a save has to go through the coordinated writer.
    func testSaveKeepsTheFileAndItOpensAgain() throws {
        let app = try launch(opening: true)
        XCTAssertTrue(element(app, "Page 1 of 3").waitForExistence(timeout: 30))

        choose(app, menu: "File", item: "Save")
        XCTAssertTrue(element(app, "Saved plain-3.pdf.").waitForExistence(timeout: 20))
        choose(app, menu: "File", item: "Close")
        XCTAssertTrue(element(app, "What would you like to do?").waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["File"].click()
        let recent = app.menuBars.menuItems["Open Recent"]
        recent.click()
        // Only this submenu: the file's name can also be a window title in the Window menu.
        let entries = recent.menuItems.matching(NSPredicate(format: "title == %@", "plain-3.pdf"))
        XCTAssertEqual(entries.count, 1, recent.menuItems.allElementsBoundByIndex.map(\.title).joined(separator: ", "))
        entries.firstMatch.click()

        XCTAssertTrue(element(app, "Page 1 of 3").waitForExistence(timeout: 30))
    }

    func testSidePanelsOpenFromTheRail() throws {
        let app = try launch(opening: true)
        XCTAssertTrue(element(app, "Page 1 of 3").waitForExistence(timeout: 30))

        for title in ["Bookmarks", "Attachments", "Comments"] {
            app.buttons[title].click()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), title)
        }
    }

    private func waitForWindows(_ app: XCUIApplication, _ count: Int) {
        let reached = NSPredicate { _, _ in app.windows.count == count }
        wait(for: [expectation(for: reached, evaluatedWith: nil)], timeout: 20)
    }

    func testMoveToNewWindowShowsTheTabThereAndHomeHere() throws {
        let app = try launch(opening: true)
        XCTAssertTrue(tab(app).waitForExistence(timeout: 30))

        tab(app).rightClick()
        app.menuItems["Move to new window"].click()

        waitForWindows(app, 2)
        XCTAssertTrue(tab(app).waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "Moved plain-3.pdf to a new window.").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "What would you like to do?").waitForExistence(timeout: 10))
    }

    func testMoveToWindowSendsTheTabBackAndTheEmptiedWindowCloses() throws {
        let app = try launch(opening: true)
        XCTAssertTrue(tab(app).waitForExistence(timeout: 30))
        tab(app).rightClick()
        app.menuItems["Move to new window"].click()
        waitForWindows(app, 2)
        XCTAssertTrue(tab(app).waitForExistence(timeout: 20))

        tab(app).rightClick()
        app.menuItems["Move to window"].click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Window ")).firstMatch.click()

        waitForWindows(app, 1)
        XCTAssertTrue(tab(app).waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "Page 1 of 3").waitForExistence(timeout: 20))
    }

    // Held a moment at the end, or the drop may be over before the destination has taken notice of the pointer.
    private func drag(_ tab: XCUIElement, to end: XCUICoordinate) {
        let start = tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    func testDraggingATabOutOfTheWindowOpensAWindowForIt() throws {
        let app = try launch(opening: true)
        XCTAssertTrue(tab(app).waitForExistence(timeout: 30))
        let start = tab(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        drag(tab(app), to: start.withOffset(CGVector(dx: 0, dy: 300)))

        waitForWindows(app, 2)
        XCTAssertTrue(element(app, "Moved plain-3.pdf to a new window.").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "What would you like to do?").waitForExistence(timeout: 10))
    }

    func testDraggingATabOntoTheStripOfAnotherWindowMovesIt() throws {
        let app = try launch(opening: true)
        XCTAssertTrue(tab(app).waitForExistence(timeout: 30))
        let start = tab(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        drag(tab(app), to: start.withOffset(CGVector(dx: 0, dy: 300)))
        waitForWindows(app, 2)
        XCTAssertTrue(element(app, "Moved plain-3.pdf to a new window.").waitForExistence(timeout: 20))

        let home = app.windows.containing(.staticText, identifier: "What would you like to do?").firstMatch
        let homeTab = home.scrollViews["Open files"].buttons["Home"]
        // The new window opens near where the drag ended, which may cover the other one's strip: move it below that.
        let mover = app.windows.containing(.staticText, identifier: "Moved plain-3.pdf to a new window.").firstMatch
        if mover.frame.intersects(homeTab.frame.insetBy(dx: -20, dy: -20)) {
            let grip = mover.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 200, dy: 12))
            grip.press(forDuration: 0.2, thenDragTo: grip.withOffset(CGVector(dx: 0, dy: homeTab.frame.maxY + 40 - mover.frame.minY)))
        }
        drag(tab(app), to: homeTab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))

        waitForWindows(app, 1)
        XCTAssertTrue(tab(app).waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "Moved plain-3.pdf to another window.").waitForExistence(timeout: 20))
    }

    // The drag of a tab is watched from behind the strip, so a plain press must still reach the tab and its close button.
    func testClickDoubleClickAndCloseOnATabStillWork() throws {
        let app = try launch(opening: true)
        XCTAssertTrue(tab(app).waitForExistence(timeout: 30))
        let strip = app.scrollViews["Open files"]

        strip.buttons["Home"].click()
        XCTAssertTrue(element(app, "What would you like to do?").waitForExistence(timeout: 10))
        tab(app).click()
        XCTAssertTrue(element(app, "Page 1 of 3").waitForExistence(timeout: 10))

        tab(app).doubleClick()
        XCTAssertTrue(tab(app).exists)
        XCTAssertTrue(element(app, "Page 1 of 3").exists)
        XCTAssertEqual(app.windows.count, 1)

        strip.buttons["Close"].click()
        XCTAssertTrue(element(app, "What would you like to do?").waitForExistence(timeout: 10))
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: tab(app))], timeout: 10)
    }
}
