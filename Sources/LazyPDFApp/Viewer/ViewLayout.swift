import Foundation

// Port of windows/LazyPDF.App/Viewer/ViewLayout.cs.

/// `columns` is 1, or 2 for facing pages. With two columns and `cover`, page 1 sits alone on the right so the next two
/// face each other. A `continuous` layout has all spreads in one scroll; otherwise only one spread is laid out.
/// `scale` is device independent pixels per point; `viewport` is what the layout centres in when it is smaller.
/// Sizes and positions are rounded to whole device pixels (`pixelsPerDip`) so tiles meet exactly.
public struct LayoutOptions {
    public var columns: Int
    public var cover: Bool
    public var continuous: Bool
    public var rotation: Int
    public var scale: Double
    public var viewport: ViewSize
    public var pixelsPerDip: Double

    public init(columns: Int, cover: Bool, continuous: Bool, rotation: Int, scale: Double, viewport: ViewSize, pixelsPerDip: Double = 1) {
        self.columns = columns
        self.cover = cover
        self.continuous = continuous
        self.rotation = rotation
        self.scale = scale
        self.viewport = viewport
        self.pixelsPerDip = pixelsPerDip
    }
}

/// Where every page of a document sits in the scrolled area: spreads (one page, or two facing) one under the other, each
/// centred. Pure arithmetic over the page sizes, so it is cheap to rebuild on every zoom.
public struct ViewLayout {
    public static let margin = 16.0
    public static let gap = 12.0

    private let rects: [ViewRect]
    private let tops: [Double]
    private let firstPage: Int

    public let options: LayoutOptions
    public let pageCount: Int

    /// The size of the scrolled area.
    public let extent: ViewSize

    /// The spread laid out first; the only one unless the layout is continuous.
    public let firstSpread: Int

    private init(options: LayoutOptions, pageCount: Int, firstSpread: Int, firstPage: Int, rects: [ViewRect], tops: [Double], extent: ViewSize) {
        self.options = options
        self.pageCount = pageCount
        self.firstSpread = firstSpread
        self.firstPage = firstPage
        self.rects = rects
        self.tops = tops
        self.extent = extent
    }

    public var spreadCount: Int { Self.spreadsOf(options.columns, options.cover, pageCount) }

    public var lastSpread: Int { firstSpread + tops.count - 1 }

    public static func spreadsOf(_ columns: Int, _ cover: Bool, _ pages: Int) -> Int {
        columns < 2 ? pages : cover ? 1 + pages / 2 : (pages + 1) / 2
    }

    public static func spreadOf(_ columns: Int, _ cover: Bool, _ page: Int) -> Int {
        columns < 2 ? page : cover ? (page + 1) / 2 : page / 2
    }

    /// The pages of a spread, in reading order.
    public static func pagesOf(_ columns: Int, _ cover: Bool, _ spread: Int, _ pages: Int) -> (first: Int, last: Int) {
        let first = columns < 2 ? spread : cover ? (spread == 0 ? 0 : 2 * spread - 1) : 2 * spread
        let count = columns < 2 || (cover && spread == 0) ? 1 : 2
        return (first, Swift.min(first + count, pages) - 1)
    }

    /// Lays out `pages` (sizes in points, as shown before rotating). In a paged layout only `spread` is placed.
    public static func build(_ pages: [ViewSize], _ options: LayoutOptions, spread: Int = 0) -> ViewLayout {
        let columns = options.columns < 2 ? 1 : 2
        var o = options
        o.columns = columns
        let spreads = spreadsOf(columns, o.cover, pages.count)
        if pages.isEmpty || spreads == 0 {
            return ViewLayout(options: o, pageCount: 0, firstSpread: 0, firstPage: 0, rects: [], tops: [], extent: o.viewport)
        }
        let first = o.continuous ? 0 : Swift.min(Swift.max(spread, 0), spreads - 1)
        let last = o.continuous ? spreads - 1 : first
        let firstPage = pagesOf(columns, o.cover, first, pages.count).first
        let lastPage = pagesOf(columns, o.cover, last, pages.count).last

        let ppd = Swift.max(o.pixelsPerDip, 1e-6)
        func snap(_ v: Double) -> Double { (v * ppd).rounded(.toNearestOrEven) / ppd }
        var sizes: [ViewSize] = []
        var widest = 0.0
        for p in firstPage...lastPage {
            let shown = PageSpace.shown(pages[p], o.rotation, o.scale)
            sizes.append(ViewSize(snap(shown.width), snap(shown.height)))
        }
        var widths: [Double] = []
        var heights: [Double] = []
        for s in first...last {
            let (a, b) = pagesOf(columns, o.cover, s, pages.count)
            var w = 0.0, h = 0.0
            for p in a...b {
                w += sizes[p - firstPage].width
                h = Swift.max(h, sizes[p - firstPage].height)
            }
            if columns == 2 { w = b > a ? w + gap : 2 * w + gap }
            widths.append(w)
            heights.append(h)
            widest = Swift.max(widest, w)
        }

        let width = Swift.max(o.viewport.width, widest + 2 * margin)
        let total = 2 * margin + heights.reduce(0, +) + gap * Double(heights.count - 1)
        let height = o.continuous ? total : Swift.max(o.viewport.height, total)
        var y = o.continuous ? margin : snap((height - total) / 2) + margin
        var rects = [ViewRect](repeating: .empty, count: sizes.count)
        var tops = [Double](repeating: 0, count: widths.count)
        for s in first...last {
            let (a, b) = pagesOf(columns, o.cover, s, pages.count)
            var x = snap((width - widths[s - first]) / 2)
            // A lone page keeps the place it would have in a pair: the cover on the right, the last page on the left.
            if columns == 2 && b == a && o.cover && s == 0 { x += sizes[a - firstPage].width + gap }
            for p in a...b {
                let size = sizes[p - firstPage]
                rects[p - firstPage] = ViewRect(x, snap(y + (heights[s - first] - size.height) / 2), size.width, size.height)
                x += size.width + gap
            }
            tops[s - first] = y
            y += heights[s - first] + gap
        }
        return ViewLayout(options: o, pageCount: pages.count, firstSpread: first, firstPage: firstPage, rects: rects, tops: tops,
                          extent: ViewSize(width, height))
    }

    /// Where a page is in the scrolled area; empty for a page the layout does not place.
    public func pageRect(_ page: Int) -> ViewRect {
        contains(page) ? rects[page - firstPage] : .empty
    }

    public func contains(_ page: Int) -> Bool {
        page - firstPage >= 0 && page - firstPage < rects.count
    }

    /// The pages whose rectangles meet `area`, in order.
    public func pagesIn(_ area: ViewRect) -> [Int] {
        if tops.isEmpty { return [] }
        var found: [Int] = []
        var spread = spreadAt(area.top)
        while spread <= lastSpread && tops[spread - firstSpread] <= area.bottom {
            let (a, b) = Self.pagesOf(options.columns, options.cover, spread, pageCount)
            for p in a...b where rects[p - firstPage].intersectsWith(area) { found.append(p) }
            spread += 1
        }
        return found
    }

    /// The page under a point of the scrolled area, or -1.
    public func pageAt(_ point: ViewPoint) -> Int {
        pagesIn(ViewRect(origin: point, size: .zero)).first { rects[$0 - firstPage].contains(point) } ?? -1
    }

    /// The page nearest to a point: the one under it, else the one whose rectangle is closest.
    public func nearestPage(_ point: ViewPoint) -> Int {
        if rects.isEmpty { return -1 }
        let spread = spreadAt(point.y)
        let (a, b) = Self.pagesOf(options.columns, options.cover, spread, pageCount)
        var best = a
        var bestDistance = Double.greatestFiniteMagnitude
        for p in a...b {
            let rect = rects[p - firstPage]
            let dx = Swift.max(0, Swift.max(rect.left - point.x, point.x - rect.right))
            let dy = Swift.max(0, Swift.max(rect.top - point.y, point.y - rect.bottom))
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = p
            }
        }
        return best
    }

    /// The page with the most of its area in `view`; the first of equals.
    public func mostVisible(_ view: ViewRect) -> Int {
        var best = -1
        var bestArea = -1.0
        for p in pagesIn(view) {
            let seen = ViewRect.intersect(rects[p - firstPage], view)
            let area = seen.isEmpty ? 0 : seen.width * seen.height
            if area > bestArea {
                bestArea = area
                best = p
            }
        }
        return best >= 0 ? best : nearestPage(view.center)
    }

    /// The top of a spread in the scrolled area.
    public func spreadTop(_ spread: Int) -> Double {
        tops[Swift.min(Swift.max(spread, firstSpread), lastSpread) - firstSpread]
    }

    private func spreadAt(_ y: Double) -> Int {
        var lo = 0, hi = tops.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tops[mid] - Self.gap / 2 <= y { lo = mid } else { hi = mid - 1 }
        }
        return firstSpread + lo
    }
}
