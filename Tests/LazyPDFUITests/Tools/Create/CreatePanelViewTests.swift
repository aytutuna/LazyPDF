#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Create panel and its sheet: drawn at the width of the inspector for each source. The model has the real
// tests, in Tests/LazyPDFAppTests/Tools/Create.

@MainActor
final class CreatePanelViewTests: XCTestCase {
    private func ink(_ model: CreateModel, height: Int = 700) throws -> Int {
        try ToolPicture.ink(try ToolPicture.draw(CreatePanelView(model: model), height: height))
    }

    func test_eachSourceIsDrawn() throws {
        let model = CreateModel(host: nil, codec: ImageIOCodec(), fonts: nil)
        let blank = try ink(model)
        XCTAssertGreaterThan(blank, 200)

        model.choose(.text)
        let text = try ink(model)
        model.choose(.pictures)
        let pictures = try ink(model)
        model.choose(.clipboard)
        let clipboard = try ink(model)

        XCTAssertNotEqual(text, blank)
        XCTAssertNotEqual(pictures, text)
        XCTAssertGreaterThan(clipboard, 0)
    }

    func test_aWrongNumberOfPagesShowsItsReason() throws {
        let model = CreateModel(host: nil, codec: ImageIOCodec(), fonts: nil)
        let fine = try ink(model)

        model.blankPages = "0"

        XCTAssertNotNil(model.blocker)
        XCTAssertGreaterThan(try ink(model), fine)
    }

    func test_theSheetIsDrawnWithItsButtons() throws {
        let model = CreateModel(host: nil, codec: ImageIOCodec(), fonts: nil)

        let image = try ToolPicture.draw(CreateSheet(model: model, close: {}), width: 400, height: 580)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 400)
    }
}
#endif
