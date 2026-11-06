import Foundation
import LazyPDFKit

// Port of the arithmetic of windows/LazyPDF.App/Viewer/PageSurface.cs and PageSurface.Tiles.cs: layout, fit, zoom, scroll
// extents and where a point or a destination lands. The Mac and iOS surfaces own one of these and draw from it. A change
// returns what the WPF surface raises as events, so the surface knows what to redraw and tell.

public struct SurfaceChange: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The scroll position or the layout changed: overlays and tools place themselves again, tiles are planned again.
    public static let view = SurfaceChange(rawValue: 1)

    /// The page in view changed, by scrolling or by going to one.
    public static let page = SurfaceChange(rawValue: 2)

    /// The zoom, the rotation or the arrangement changed.
    public static let options = SurfaceChange(rawValue: 4)

    /// The zoom changed, so tiles should wait for it to settle before the sharp ones are asked for.
    public static let zoom = SurfaceChange(rawValue: 8)
}

public struct PageSurfaceState {
    public static let lineStep = 48.0

    private var raised: SurfaceChange = []
    private var pinned = false
    private var nextVersion = 0
    private var pageObjects: [Int] = []

    public private(set) var sizes: [ViewSize] = []
    public private(set) var layout = ViewLayout.build([], LayoutOptions(columns: 1, cover: false, continuous: true, rotation: 0, scale: 1, viewport: .zero))
    public private(set) var viewport = ViewSize.zero
    public private(set) var offsetX = 0.0
    public private(set) var offsetY = 0.0
    public private(set) var zoom = 1.0
    public private(set) var fit = FitMode.none
    public private(set) var rotation = 0
    public private(set) var columns = 1
    public private(set) var cover = false
    public private(set) var continuous = true
    public private(set) var tint = PageTint.none
    public private(set) var currentPage = 0

    /// The number that names the content of each page's pictures; it changes only when an edit touched the page.
    public private(set) var versions: [Int] = []

    /// Device pixels per device independent pixel; offsets and positions are kept to whole device pixels.
    public private(set) var pixelsPerDip = 1.0

    public init() {}

    public var pageCount: Int { sizes.count }

    /// The part of the scrolled area in view.
    public var viewRect: ViewRect { ViewRect(offsetX, offsetY, viewport.width, viewport.height) }

    public var extent: ViewSize { layout.extent }

    /// The page size in points as it is shown before rotating.
    public func pageSize(_ page: Int) -> ViewSize {
        page >= 0 && page < sizes.count ? sizes[page] : .zero
    }

    /// The zoom range for this document.
    public var zoomLimits: (min: Double, max: Double) {
        ZoomMath.limits(sizes.isEmpty ? 792 : sizes.map { Swift.max($0.width, $0.height) }.max()!, pixelsPerDip)
    }

    /// How far a page down or page up scrolls.
    public var pageStep: Double { Swift.max(Self.lineStep, viewport.height * 0.9) }

    /// Device independent pixels per point.
    var scale: Double { zoom * PageSpace.dipPerPoint }

    /// The sizes of the pages in points as shown: the renderer's, or the engine's when the system cannot draw the file
    /// (`renderer` nil) or has no size for a page.
    public static func pageSizes(_ document: PdfDocument, _ renderer: DocumentRenderer?) -> [ViewSize] {
        let pages = document.pages
        return (0..<pages.count).map { i in
            var (w, h) = renderer?.pageSize(i) ?? (0, 0)
            if w <= 0 || h <= 0 {
                let geometry = PageGeometry(pages[i])
                (w, h) = (geometry.width, geometry.height)
            }
            return ViewSize(w, h)
        }
    }

    /// The object number of each page, to tell later which pages are the same ones.
    public static func pageObjects(_ document: PdfDocument) -> [Int] {
        document.pages.map { $0.reference.number }
    }


    /// Shows a document. `zoom` and `fit` are what the tab remembers: a zoom with no fit is kept, anything else fits the width
    /// unless the tab was fitted to the page.
    public mutating func show(sizes: [ViewSize], pageObjects: [Int], page: Int, zoom tabZoom: Double, fit tabFit: FitMode) -> SurfaceChange {
        collecting { s in
            s.offsetX = 0
            s.offsetY = 0
            s.sizes = sizes
            s.versions = [Int](repeating: 0, count: sizes.count)
            s.pageObjects = pageObjects
            s.currentPage = Swift.min(Swift.max(page, 0), Swift.max(0, sizes.count - 1))
            s.pinned = true
            let limits = s.zoomLimits
            if tabFit == .none && tabZoom > 0 {
                s.fit = .none
                s.zoom = ZoomMath.clamp(tabZoom, limits)
            } else {
                s.fit = tabFit == .none ? .width : tabFit
                s.zoom = s.viewport.width > 0 && !sizes.isEmpty ? ZoomMath.clamp(s.fitZoom(), limits) : 1
            }
            s.rebuild(nil, .zero, nil)
            s.goToPageInner(s.currentPage, nil)
            s.raised.formUnion([.page, .options])
        }
    }

    /// Shows nothing.
    public mutating func clear() {
        sizes = []
        versions = []
        pageObjects = []
        offsetX = 0
        offsetY = 0
        currentPage = 0
        pinned = true
        layout = ViewLayout.build([], LayoutOptions(columns: columns, cover: cover, continuous: continuous, rotation: rotation, scale: scale, viewport: viewport, pixelsPerDip: pixelsPerDip))
    }

    /// The file's bytes changed. The scroll position stays on what it was on, and only pages the change can have touched get
    /// new pictures: `changed` is `RevisionDiff.changed` of the old and new bytes (nil when everything counts as changed) and
    /// `touches` asks `RevisionDiff.touches` for a page.
    public mutating func reload(sizes: [ViewSize], pageObjects objects: [Int], changed: Set<Int>?, touches: (Int) -> Bool) -> SurfaceChange {
        collecting { s in
            let anchor = s.anchorAt(.zero)
            let near: Set<Int> = s.layout.pageCount == 0 ? [] : Set(s.layout.pagesIn(s.viewRect.inflated(s.viewRect.width, s.viewRect.height * 2)))
            var versions = [Int](repeating: 0, count: sizes.count)
            for i in versions.indices {
                let same = changed != nil && i < s.pageObjects.count && s.pageObjects[i] == objects[i] && near.contains(i) && !touches(i)
                if same {
                    versions[i] = s.versions[i]
                } else {
                    s.nextVersion += 1
                    versions[i] = s.nextVersion
                }
            }
            s.pageObjects = objects
            s.versions = versions
            s.sizes = sizes
            s.currentPage = Swift.min(Swift.max(s.currentPage, 0), Swift.max(0, sizes.count - 1))
            if s.fit != .none { s.zoom = s.fitZoom() }
            s.zoom = ZoomMath.clamp(s.zoom, s.zoomLimits)
            s.rebuild(nil, .zero, anchor)
            s.raised.formUnion([.page, .options])
        }
    }

    /// Gives every page new pictures, as when the pages are drawn from another renderer.
    public mutating func renewVersions() {
        for i in versions.indices {
            nextVersion += 1
            versions[i] = nextVersion
        }
    }


    public mutating func setZoom(_ zoom: Double, around: ViewPoint? = nil) -> SurfaceChange {
        collecting { s in
            s.fit = .none
            s.changeZoom(zoom, around)
        }
    }

    private mutating func changeZoom(_ requested: Double, _ around: ViewPoint?) {
        let zoom = ZoomMath.clamp(requested, zoomLimits)
        if abs(zoom - self.zoom) < 1e-9 && fit == .none { return }
        let point = around ?? ViewPoint(viewport.width / 2, viewport.height / 2)
        let anchor = anchorAt(point)
        self.zoom = zoom
        rebuild(nil, point, anchor)
        raised.formUnion([.zoom, .options])
    }

    public mutating func setFit(_ fit: FitMode) -> SurfaceChange {
        collecting { s in
            s.fit = fit
            if fit == .none { return }
            let anchor = s.anchorAt(.zero)
            s.zoom = ZoomMath.clamp(s.fitZoom(), s.zoomLimits)
            s.rebuild(nil, .zero, anchor)
            if !s.continuous || fit == .page { s.goToPageInner(s.currentPage, nil) }
            s.raised.formUnion([.zoom, .options])
        }
    }

    public mutating func setArrangement(columns: Int, cover: Bool, continuous: Bool) -> SurfaceChange {
        collecting { s in
            let wanted = columns < 2 ? 1 : 2
            if wanted == s.columns && cover == s.cover && continuous == s.continuous { return }
            s.columns = wanted
            s.cover = cover
            s.continuous = continuous
            if s.fit != .none { s.zoom = ZoomMath.clamp(s.fitZoom(), s.zoomLimits) }
            s.rebuild(nil, .zero, nil)
            s.goToPageInner(s.currentPage, nil)
            s.raised.insert(.options)
        }
    }

    public mutating func setRotation(_ degrees: Int) -> SurfaceChange {
        collecting { s in
            let turned = PageSpace.normalizeRotation(degrees)
            if turned == s.rotation { return }
            let anchor = s.anchorAt(.zero)
            s.rotation = turned
            if s.fit != .none { s.zoom = ZoomMath.clamp(s.fitZoom(), s.zoomLimits) }
            s.rebuild(nil, .zero, anchor)
            s.raised.insert(.options)
        }
    }

    /// The caller clears its pictures when this reports a change.
    public mutating func setTint(_ tint: PageTint) -> SurfaceChange {
        if tint == self.tint { return [] }
        self.tint = tint
        return [.view, .options]
    }

    /// The size the surface has been given. A fitted zoom follows it.
    public mutating func setViewport(_ size: ViewSize) -> SurfaceChange {
        collecting { s in
            if size == s.viewport { return }
            let anchor = s.anchorAt(.zero)
            s.viewport = size
            if s.fit != .none && !s.sizes.isEmpty { s.zoom = ZoomMath.clamp(s.fitZoom(), s.zoomLimits) }
            s.rebuild(nil, .zero, anchor)
            s.raised.formUnion([.zoom, .options])
        }
    }

    public mutating func setPixelsPerDip(_ value: Double) -> SurfaceChange {
        guard value > 0, value.isFinite else { return [] }
        return collecting { s in
            s.pixelsPerDip = value
            let anchor = s.anchorAt(.zero)
            s.rebuild(nil, .zero, anchor)
            s.raised.insert(.zoom)
        }
    }

    // The zoom that fits the current spread, from the sizes of its pages as they are shown.
    private func fitZoom() -> Double {
        if sizes.isEmpty { return zoom }
        let (first, last) = ViewLayout.pagesOf(columns, cover, ViewLayout.spreadOf(columns, cover, currentPage), sizes.count)
        var width = 0.0, height = 0.0
        for p in first...last {
            let shown = PageSpace.shown(sizes[p], rotation, 1)
            width += shown.width
            height = Swift.max(height, shown.height)
        }
        if columns == 2 && last == first { width *= 2 }
        let room = ViewSize(Swift.max(0, viewport.width - (columns == 2 ? ViewLayout.gap : 0)), viewport.height)
        let spread = ViewSize(width, height)
        return fit == .width ? ZoomMath.fitWidth(spread.width, room) : ZoomMath.fitPage(spread, room)
    }


    // A point on a page that stays where it is on screen while the layout around it changes.
    private struct Anchor {
        let page: Int
        let point: ViewPoint
    }

    private func anchorAt(_ viewPoint: ViewPoint) -> Anchor? {
        if layout.pageCount == 0 { return nil }
        let content = ViewPoint(viewPoint.x + offsetX, viewPoint.y + offsetY)
        let page = layout.nearestPage(content)
        if page < 0 { return nil }
        return Anchor(page: page, point: PageSpace.toPage(contentMatrix(page)).transform(content))
    }

    // Lays the pages out again and puts the anchor back where it was on the screen.
    private mutating func rebuild(_ spread: Int?, _ viewPoint: ViewPoint, _ anchor: Anchor?) {
        layout = ViewLayout.build(sizes, LayoutOptions(columns: columns, cover: cover, continuous: continuous, rotation: rotation, scale: scale,
                                                       viewport: viewport, pixelsPerDip: pixelsPerDip),
                                  spread: spread ?? ViewLayout.spreadOf(columns, cover, currentPage))
        if let anchor, layout.contains(anchor.page) {
            let content = contentMatrix(anchor.page).transform(anchor.point)
            offsetX = content.x - viewPoint.x
            offsetY = content.y - viewPoint.y
        }
        clampOffset()
        afterScroll(user: false)
    }

    /// Takes a point of a page to the scrolled area (before the scroll offset).
    func contentMatrix(_ page: Int) -> ViewMatrix {
        PageSpace.toView(sizes[page], rotation, scale, layout.pageRect(page).topLeft)
    }

    /// Takes a point of page space to the surface; nil when the page is not laid out (the other pages of a paged layout).
    public func pageMatrix(_ page: Int) -> ViewMatrix? {
        guard page >= 0 && page < sizes.count && layout.contains(page) else { return nil }
        return contentMatrix(page).translated(-offsetX, -offsetY)
    }

    /// The page under a point of the surface, with the point in page space. `nearest` takes the closest page when the point
    /// is between pages.
    public func hit(_ surfacePoint: ViewPoint, nearest: Bool = false) -> (page: Int, point: ViewPoint)? {
        let content = ViewPoint(surfacePoint.x + offsetX, surfacePoint.y + offsetY)
        var page = layout.pageAt(content)
        if page < 0 && nearest { page = layout.nearestPage(content) }
        if page < 0 { return nil }
        return (page, PageSpace.toPage(contentMatrix(page)).transform(content))
    }


    /// Scrolls to a page. With `at` (page space) that point comes to the top of the view, whatever the rotation.
    public mutating func goToPage(_ page: Int, at: ViewPoint? = nil) -> SurfaceChange {
        collecting { s in s.goToPageInner(page, at) }
    }

    private mutating func goToPageInner(_ requested: Int, _ at: ViewPoint?) {
        if sizes.isEmpty { return }
        let page = Swift.min(Swift.max(requested, 0), sizes.count - 1)
        currentPage = page
        pinned = true
        let spread = ViewLayout.spreadOf(columns, cover, page)
        if !continuous && spread != layout.firstSpread {
            if fit != .none { zoom = ZoomMath.clamp(fitZoom(), zoomLimits) }
            rebuild(spread, .zero, nil)
        }
        let rect = layout.pageRect(page)
        if let at { offsetY = contentMatrix(page).transform(at).y } else { offsetY = continuous ? rect.top - ViewLayout.margin : 0 }
        if layout.extent.width > viewport.width { offsetX = Swift.max(0, rect.left + rect.width / 2 - viewport.width / 2) }
        clampOffset()
        afterScroll(user: false)
        raised.insert(.page)
    }

    /// Scrolls so that `area` (page space) is in view, centred when it is not already.
    public mutating func reveal(_ page: Int, _ area: ViewRect) -> SurfaceChange {
        collecting { s in
            guard page >= 0 && page < s.sizes.count else { return }
            if !s.layout.contains(page) { s.goToPageInner(page, nil) }
            let shown = PageSpace.transform(s.contentMatrix(page), area)
            let view = s.viewRect
            let margin = ViewSize(Swift.min(48, view.width / 4), Swift.min(48, view.height / 4))
            let inner = ViewRect(view.left + margin.width, view.top + margin.height, view.width - 2 * margin.width, view.height - 2 * margin.height)
            if inner.contains(shown) { return }
            s.pinned = true
            s.currentPage = page
            s.offsetY = shown.top + shown.height / 2 - view.height / 2
            if s.layout.extent.width > view.width { s.offsetX = shown.left + shown.width / 2 - view.width / 2 }
            s.clampOffset()
            s.afterScroll(user: false)
            s.raised.insert(.page)
        }
    }

    /// Scrolls by the user's doing. In a paged layout, running past the edge turns the page.
    public mutating func scrollBy(_ dx: Double, _ dy: Double) -> SurfaceChange {
        collecting { s in
            let maxY = Swift.max(0, s.layout.extent.height - s.viewport.height)
            if !s.continuous && dy > 0 && s.offsetY >= maxY - 0.5 && s.layout.lastSpread < s.layout.spreadCount - 1 {
                s.goToPageInner(ViewLayout.pagesOf(s.columns, s.cover, s.layout.lastSpread + 1, s.sizes.count).first, nil)
                return
            }
            if !s.continuous && dy < 0 && s.offsetY <= 0.5 && s.layout.firstSpread > 0 {
                s.goToPageInner(ViewLayout.pagesOf(s.columns, s.cover, s.layout.firstSpread - 1, s.sizes.count).first, nil)
                s.offsetY = Swift.max(0, s.layout.extent.height - s.viewport.height)
                s.afterScroll(user: false)
                return
            }
            s.offsetX += dx
            s.offsetY += dy
            s.clampOffset()
            s.afterScroll(user: true)
        }
    }

    /// Scrolls to an offset, as a scroll bar does.
    public mutating func scrollTo(x: Double, y: Double) -> SurfaceChange {
        scrollBy(x - offsetX, y - offsetY)
    }

    private mutating func clampOffset() {
        // Whole device pixels, so tiles keep their sharpness while scrolling.
        let ppd = Swift.max(pixelsPerDip, 1e-6)
        offsetX = (Swift.min(Swift.max(offsetX, 0), Swift.max(0, layout.extent.width - viewport.width)) * ppd).rounded(.toNearestOrEven) / ppd
        offsetY = (Swift.min(Swift.max(offsetY, 0), Swift.max(0, layout.extent.height - viewport.height)) * ppd).rounded(.toNearestOrEven) / ppd
    }

    private mutating func afterScroll(user: Bool) {
        if user { pinned = false }
        if !pinned && layout.pageCount > 0 {
            let page = layout.mostVisible(viewRect)
            if page >= 0 && page != currentPage {
                currentPage = page
                raised.insert(.page)
            }
        }
        raised.insert(.view)
    }

    private mutating func collecting(_ body: (inout PageSurfaceState) -> Void) -> SurfaceChange {
        raised = []
        body(&self)
        return raised
    }
}
