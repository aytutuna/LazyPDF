import XCTest

// The fixture is a PDF in this bundle. The app opens it from the hidden `-uitestOpen <path>` launch argument, which only a
// simulator build honours.
final class DocumentTests: XCTestCase {
    @MainActor
    private func launch(opening: Bool = true) throws -> XCUIApplication {
        let app = XCUIApplication()
        if opening {
            let fixture = try XCTUnwrap(Bundle(for: DocumentTests.self).url(forResource: "text-pages", withExtension: "pdf"))
            app.launchArguments = ["-uitestOpen", fixture.path]
        }
        app.launch()
        return app
    }

    @MainActor
    private func firstPage(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Page 1 of'")).firstMatch
    }

    @MainActor
    func testLaunchShowsHome() throws {
        let app = try launch(opening: false)
        XCTAssertTrue(app.staticTexts["What would you like to do?"].firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Open"].firstMatch.exists)
    }

    @MainActor
    func testFixtureOpensWithItsFirstPage() throws {
        let app = try launch()
        XCTAssertTrue(firstPage(app).waitForExistence(timeout: 60))
        XCTAssertFalse(app.staticTexts["What would you like to do?"].firstMatch.exists)
    }

    @MainActor
    func testFindFindsAWord() throws {
        let app = try launch()
        XCTAssertTrue(firstPage(app).waitForExistence(timeout: 60))
        app.buttons["Search"].firstMatch.tap()
        let field = app.textFields["Search text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("Quarterly")
        let count = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\d+ of \\d+")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["No results"].firstMatch.exists)
    }

    @MainActor
    func testSidePanelOpensAsASheet() throws {
        let app = try launch()
        XCTAssertTrue(firstPage(app).waitForExistence(timeout: 60))
        app.buttons["Side panels"].firstMatch.tap()
        app.buttons["Pages"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Pages"].waitForExistence(timeout: 10))
        app.navigationBars["Pages"].buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Pages"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testClosingTheDocumentGoesBackToHome() throws {
        let app = try launch()
        XCTAssertTrue(firstPage(app).waitForExistence(timeout: 60))
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["What would you like to do?"].firstMatch.waitForExistence(timeout: 10))
    }
}
