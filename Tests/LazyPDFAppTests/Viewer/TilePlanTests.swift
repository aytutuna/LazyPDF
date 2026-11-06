import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/TilePlanTests.cs: cutting a page into the tiles the renderer is asked for.

final class TilePlanTests: XCTestCase {
    private func exact(_ pixels: Int) -> Int { pixels }

    // Sizes the way Windows makes them: a request in whole units of 1.4 pixels.
    private func scaled(_ pixels: Int) -> Int {
        Int((Swift.max(1, (Double(pixels) / 1.4).rounded(.toNearestOrEven)) * 1.4).rounded(.toNearestOrEven))
    }

    private func cover(_ page: ViewSize, _ scale: Double, _ area: ViewRect, _ reachable: ((Int) -> Int)? = nil) -> [TileSpec] {
        TilePlan.cover(3, 7, .none, page, scale, area, reachable ?? exact)
    }

    func test_aWholePageIsAGridOfTilesThatMeetTheEdges() {
        let tiles = cover(ViewSize(612, 792), 2, ViewRect(0, 0, 1224, 1584))

        XCTAssertEqual(tiles.count, 3 * 4)
        XCTAssertTrue(tiles.allSatisfy { $0.key.page == 3 && $0.key.version == 7 })
        let last = tiles[tiles.count - 1]
        XCTAssertEqual(last.x, 2 * 512)
        XCTAssertEqual(last.y, 3 * 512)
        XCTAssertEqual(last.width, 1224 - 1024)
        XCTAssertEqual(last.height, 1584 - 1536)
        XCTAssertEqual(tiles.filter { $0.key.column == 0 }.reduce(0) { $0 + $1.height }, 1584)
    }

    func test_onlyTheTilesTheAreaMeetsAreWanted() {
        let tiles = cover(ViewSize(612, 792), 2, ViewRect(600, 520, 100, 10))

        XCTAssertEqual(tiles.map { [$0.key.column, $0.key.row] }, [[1, 1]])
    }

    func test_anAreaOffThePageGivesNothing() {
        XCTAssertTrue(cover(ViewSize(100, 100), 1, ViewRect(500, 500, 10, 10)).isEmpty)
        XCTAssertTrue(cover(ViewSize(100, 100), 1, .empty).isEmpty)
    }

    func test_anAreaWiderThanThePageIsCutToIt() {
        let tiles = cover(ViewSize(100, 100), 1, ViewRect(-50, -50, 900, 900))

        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual([tiles[0].width, tiles[0].height], [100, 100])
    }

    func test_theGridStepIsTheNearestSizeTheRendererMakes() {
        func coarse(_ pixels: Int) -> Int { (pixels + 7) / 8 * 8 + 3 }

        let tiles = cover(ViewSize(612, 792), 2, ViewRect(0, 0, 1224, 1584), coarse)

        XCTAssertEqual(tiles.first { $0.key.column == 1 }?.x, 515)
        XCTAssertEqual(tiles.first { $0.key.row == 1 }?.y, 515)
    }

    func test_aLastTileReachesTheEdgeEvenWhenItsSizeIsNotMadeExactly() {
        for width in 1..<700 {
            let tiles = cover(ViewSize(Double(width), 50), 1, ViewRect(0, 0, Double(width), 50), scaled)

            let last = tiles.filter { $0.key.row == 0 }.last!
            XCTAssertTrue(last.x + scaled(last.width) >= width, "width \(width)")
        }
    }

    func test_theKeyOfATileNamesItsPlaceAndScale() {
        let tile = cover(ViewSize(612, 792), 1.5, ViewRect(600, 0, 10, 10))[0]

        XCTAssertEqual(tile.key, TileKey(3, 7, 1.5, 1, 0, .none))
        XCTAssertFalse(tile.key.isPreview)
    }

    func test_thePreviewIsTheWholePageAtALowScale() {
        let preview = TilePlan.preview(2, 5, .dark, ViewSize(600, 800))

        XCTAssertTrue(preview.key.isPreview)
        XCTAssertEqual(preview.key.scale, TilePlan.previewScale(ViewSize(600, 800)))
        XCTAssertEqual(preview.height, TilePlan.previewSide)
        XCTAssertEqual(preview.width, 480)
        XCTAssertEqual(preview.key.tint, .dark)
    }

    func test_aTileLiesWhereItsPixelsAreOnThePage() {
        let tile = cover(ViewSize(612, 792), 2, ViewRect(600, 520, 100, 10))[0]

        let rect = TilePlan.pointsRect(tile, 512, 512)

        XCTAssertEqual(rect, ViewRect(256, 256, 256, 256))
    }
}
