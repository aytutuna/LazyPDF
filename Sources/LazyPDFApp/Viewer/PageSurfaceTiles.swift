import Foundation

// Port of PlanTiles in windows/LazyPDF.App/Viewer/PageSurface.Tiles.cs: which tiles the window needs, in the order to draw them.

extension PageSurfaceState {
    private static let maxWanted = 96

    /// Whatever of the pages near the window is not drawn yet: first the previews of what is in view, then its tiles, then the
    /// previews and tiles around it. A lower priority number is drawn sooner. `isKnown` says a tile is already held or has
    /// failed; while `settling` (the zoom just changed) only previews are asked for.
    public func wantedTiles(settling: Bool, isKnown: (TileKey) -> Bool, reachable: (Int) -> Int) -> [(spec: TileSpec, priority: Double)] {
        if layout.pageCount == 0 { return [] }
        let ppp = scale * pixelsPerDip
        let view = viewRect
        let near = view.inflated(view.width * 0.5, view.height)
        let far = view.inflated(view.width, view.height * 2)
        let center = view.center
        var wanted: [(spec: TileSpec, priority: Double)] = []
        for page in layout.pagesIn(far) {
            let rect = layout.pageRect(page)
            let preview = TilePlan.preview(page, versions[page], tint, sizes[page])
            if !isKnown(preview.key) {
                wanted.append((preview, (rect.intersectsWith(view) ? 0 : 2e6) + Self.distance(rect, center)))
            }
            if settling || ppp <= preview.key.scale || !rect.intersectsWith(near) { continue }
            for tile in required(page, ViewRect.intersect(rect, near), reachable) where !isKnown(tile.key) {
                let box = contentRect(page, tile)
                wanted.append((tile, (box.intersectsWith(view) ? 1e6 : 3e6) + Self.distance(box, center)))
            }
        }
        if wanted.count > Self.maxWanted { wanted = Array(wanted.sorted { $0.priority < $1.priority }.prefix(Self.maxWanted)) }
        return wanted
    }

    private static func distance(_ rect: ViewRect, _ from: ViewPoint) -> Double {
        abs(rect.center.x - from.x) + abs(rect.center.y - from.y)
    }

    // The tiles of a page at the current zoom that cover a part of it given in the scrolled area's coordinates.
    func required(_ page: Int, _ contentArea: ViewRect, _ reachable: (Int) -> Int) -> [TileSpec] {
        let ppp = scale * pixelsPerDip
        let points = PageSpace.transform(PageSpace.toPage(contentMatrix(page)), contentArea)
        let pixels = ViewRect(points.x * ppp, points.y * ppp, points.width * ppp, points.height * ppp)
        return TilePlan.cover(page, versions[page], tint, sizes[page], ppp, pixels, reachable)
    }

    private func contentRect(_ page: Int, _ tile: TileSpec) -> ViewRect {
        PageSpace.transform(contentMatrix(page), TilePlan.pointsRect(tile, tile.width, tile.height))
    }
}
