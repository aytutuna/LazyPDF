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

    // The small menu buttons of the phone layout cannot be scrolled to by the accessibility action; a tap at their middle works.
    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
        tap(app.buttons["Side panels"].firstMatch)
        app.buttons["Pages"].firstMatch.tap()
        // The half-height sheet shows its grabber; the buttons inside it are not reachable at that size.
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: bottom)
        if grabber.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        XCTAssertTrue(grabber.waitForNonExistence(timeout: 10))
    }

    // The page above a tool's sheet takes the touches, so a tool can be used with the sheet open; a tap there leaves the sheet.
    @MainActor
    func testToolSheetStaysOpenWhenThePageBehindItIsTouched() throws {
        let app = try launch()
        XCTAssertTrue(firstPage(app).waitForExistence(timeout: 60))
        tap(app.buttons["Tools"].firstMatch)
        // The list builds its rows lazily, so a row far down the catalog is not there until searched for.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Properties")
        let row = app.buttons["Properties"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let grabber = app.buttons["Sheet Grabber"].firstMatch
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()

        XCTAssertFalse(grabber.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testClosingTheDocumentGoesBackToHome() throws {
        let app = try launch()
        XCTAssertTrue(firstPage(app).waitForExistence(timeout: 60))
        tap(app.buttons["More"].firstMatch)
        tap(app.buttons["Close"].firstMatch)
        XCTAssertTrue(app.staticTexts["What would you like to do?"].firstMatch.waitForExistence(timeout: 10))
    }
}
