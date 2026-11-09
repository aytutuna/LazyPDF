#if canImport(SwiftUI)
import SwiftUI
import XCTest
import LazyPDFKit
import LazyPDFApp
@testable import LazyPDFUI

// A smoke test of the Batch panel and its sheet: drawn at the width of the inspector with each kind of step open. The model has
// the real tests, in Tests/LazyPDFAppTests/Tools/Batch.

@MainActor
final class BatchPanelViewTests: XCTestCase {
    private func model(_ folder: TempDir) -> BatchModel {
        BatchModel(host: nil, settings: folder.url, bookmarks: nil, watcher: nil, runner: AppleBatch.runner)
    }

    private func ink(_ model: BatchModel, height: Int = 1400) throws -> Int {
        try ToolPicture.ink(try ToolPicture.draw(BatchPanelView(model: model), height: height))
    }

    func test_eachKindOfStepAddsItsEditor() throws {
        let model = model(TempDir(self))
        let empty = try ink(model)
        XCTAssertGreaterThan(empty, 200)

        var seen = Set<Int>()
        for kind in BatchStepKind.allCases {
            model.addStep(kind)
            let drawn = try ink(model)
            XCTAssertGreaterThan(drawn, empty, "\(kind)")
            seen.insert(drawn)
        }
        XCTAssertGreaterThan(seen.count, 3)
    }

    func test_theWatchIsDrawnOnlyWhereThePlatformOffersIt() throws {
        let dir = TempDir(self)
        let without = model(dir)
        let with = BatchModel(host: nil, settings: dir.url, bookmarks: nil, watcher: { _, _, _ in throw CocoaError(.fileReadUnknown) },
                              runner: AppleBatch.runner)

        XCTAssertGreaterThan(try ink(with), try ink(without))
    }

    func test_theSheetIsDrawnWithItsButtons() throws {
        let model = model(TempDir(self))

        let image = try ToolPicture.draw(BatchSheet(model: model, close: {}), width: 440, height: 640)

        XCTAssertGreaterThan(try ToolPicture.ink(image), 400)
    }
}
#endif
