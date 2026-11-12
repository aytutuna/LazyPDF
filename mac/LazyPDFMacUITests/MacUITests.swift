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
}
