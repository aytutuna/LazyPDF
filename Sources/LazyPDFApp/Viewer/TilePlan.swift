import Foundation

// Port of windows/LazyPDF.App/Viewer/TilePlan.cs: cuts a page into the tiles that are drawn through the renderer.

/// One picture of a page. `scale` is device pixels per point. A tile is a square-ish piece of the page at that scale, in a
/// fixed grid; a preview (`column` -1) is the whole page at a low scale. `version` changes when the page's own content
/// changes, so a page an edit did not touch keeps its pictures.
public struct TileKey: Hashable {
    public let page: Int
    public let version: Int
    public let scale: Double
    public let column: Int
    public let row: Int
    public let tint: PageTint

    public init(_ page: Int, _ version: Int, _ scale: Double, _ column: Int, _ row: Int, _ tint: PageTint) {
        self.page = page
        self.version = version
        self.scale = scale
        self.column = column
        self.row = row
        self.tint = tint
    }

    public var isPreview: Bool { column < 0 }
}

/// A tile and the pixels of the page it covers, in the pixels of the page at the tile's scale.
public struct TileSpec: Equatable {
    public let key: TileKey
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(_ key: TileKey, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        self.key = key
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum TilePlan {
    public static let tileSize = 512

    /// The longest side, in pixels, of the picture of a whole page that stands in while the tiles come.
    public static let previewSide = 640

    /// `area` is the part of the page that is wanted, in pixels of the page at `scale`. `reachable` gives the size nearest a
    /// given one that the renderer can make.
    public static func cover(_ page: Int, _ version: Int, _ tint: PageTint, _ pagePoints: ViewSize, _ scale: Double, _ area: ViewRect,
                             _ reachable: (Int) -> Int) -> [TileSpec] {
        var tiles: [TileSpec] = []
        let step = reachable(tileSize)
        let width = Int((pagePoints.width * scale).rounded(.up)), height = Int((pagePoints.height * scale).rounded(.up))
        let area = ViewRect.intersect(area, ViewRect(0, 0, Double(width), Double(height)))
        if area.isEmpty || step <= 0 { return tiles }
        let c0 = Int(area.left / Double(step)), c1 = Int((area.right / Double(step)).rounded(.up)) - 1
        let r0 = Int(area.top / Double(step)), r1 = Int((area.bottom / Double(step)).rounded(.up)) - 1
        if r0 > r1 || c0 > c1 { return tiles }
        for r in r0...r1 {
            for c in c0...c1 {
                let x = c * step, y = r * step
                tiles.append(TileSpec(TileKey(page, version, scale, c, r, tint), x, y,
                                      fit(width - x, step, reachable), fit(height - y, step, reachable)))
            }
        }
        return tiles
    }

    /// The scale of the preview of a page, in pixels per point.
    public static func previewScale(_ pagePoints: ViewSize) -> Double {
        Double(previewSide) / Swift.max(Swift.max(pagePoints.width, pagePoints.height), 1)
    }

    public static func preview(_ page: Int, _ version: Int, _ tint: PageTint, _ pagePoints: ViewSize) -> TileSpec {
        let scale = previewScale(pagePoints)
        return TileSpec(TileKey(page, version, scale, -1, -1, tint), 0, 0,
                        Int((pagePoints.width * scale).rounded(.up)), Int((pagePoints.height * scale).rounded(.up)))
    }

    /// Where a tile lies on the page, in points; `width` and `height` are the size of the picture that came back.
    public static func pointsRect(_ tile: TileSpec, _ width: Int, _ height: Int) -> ViewRect {
        let scale = tile.key.scale
        return ViewRect(Double(tile.x) / scale, Double(tile.y) / scale, Double(width) / scale, Double(height) / scale)
    }

    // The renderer cannot make every size; the last tile of a row takes the smallest it can make that still reaches the edge.
    private static func fit(_ remaining: Int, _ step: Int, _ reachable: (Int) -> Int) -> Int {
        if remaining >= step { return step }
        for size in remaining..<(remaining + 8) where reachable(size) >= remaining {
            return size
        }
        return remaining
    }
}
