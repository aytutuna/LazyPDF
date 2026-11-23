import Foundation

// Where the page view puts the text control of an OverlayField. The control is upright whatever the viewer's rotation, so it
// is the size of the field's area times the scale, centred on where the turned area lands, and not the bounding box of that.

public enum OverlayFieldFrame {
    /// The frame in the viewer's view. `used` is the room the text takes at the control's width; the frame grows to hold it,
    /// downwards for every field and to the right as well for one that does not wrap.
    ///
    /// With `bounds`, the page's rectangle in the same view, the first-size frame is shifted, never resized, until it lies in
    /// the page; on an axis where it does not fit it is aligned to the page's top or left. That happens once, before any
    /// growth. Growth starts from that fixed top left and stops at the page's right and bottom edges, the text scrolling
    /// inside the control past them. A control that cannot scroll sideways (`scrollsAcross` false) is not capped in width.
    public static func of(_ area: ViewRect, _ matrix: ViewMatrix, used: ViewSize?, wraps: Bool,
                          bounds: ViewRect? = nil, scrollsAcross: Bool = true) -> ViewRect {
        let scale = ViewScale.of(matrix)
        let turned = PageSpace.transform(matrix, area)
        let width = area.width * scale
        let height = area.height * scale
        var x = turned.x + (turned.width - width) / 2
        var y = turned.y + (turned.height - height) / 2
        if let bounds {
            x = fit(x, width, bounds.x, bounds.width)
            y = fit(y, height, bounds.y, bounds.height)
        }
        guard let used else { return ViewRect(x, y, width, height) }
        var grownWidth = wraps ? width : Swift.max(width, used.width)
        var grownHeight = Swift.max(height, used.height)
        if let bounds {
            if !wraps && scrollsAcross { grownWidth = Swift.max(width, Swift.min(grownWidth, bounds.right - x)) }
            grownHeight = Swift.max(height, Swift.min(grownHeight, bounds.bottom - y))
        }
        return ViewRect(x, y, grownWidth, grownHeight)
    }

    /// The upright footprint in page space of the control of a field with `area`, on a view turned by `rotation`, as `of` places
    /// it against the edges of a page of `page` points: what to reveal so the whole control is in view.
    public static func uprightPageRect(_ area: ViewRect, rotation: Int, page: ViewSize) -> ViewRect {
        let turn = PageSpace.normalizeRotation(rotation)
        let quarter = turn == 90 || turn == 270
        let width = quarter ? area.height : area.width
        let height = quarter ? area.width : area.height
        let x = area.x + (area.width - width) / 2
        let y = area.y + (area.height - height) / 2
        // The corner at the screen's top left is on the page's right edge from 180 on, and on its bottom edge at 90 and 180.
        let atRight = turn == 180 || turn == 270
        let atBottom = turn == 90 || turn == 180
        return ViewRect(fitInPage(x, width, page.width, atRight), fitInPage(y, height, page.height, atBottom), width, height)
    }

    /// Where a page point lands in the control's own coordinates: its top left is the area's top left, and the control is the
    /// area scaled, so the turn of the view does not come into it.
    public static func local(_ point: ViewPoint, in area: ViewRect, scale: Double) -> ViewPoint {
        ViewPoint((point.x - area.x) * scale, (point.y - area.y) * scale)
    }

    private static func fit(_ start: Double, _ length: Double, _ edge: Double, _ room: Double) -> Double {
        length > room ? edge : Swift.min(Swift.max(start, edge), edge + room - length)
    }

    private static func fitInPage(_ start: Double, _ length: Double, _ room: Double, _ atEnd: Bool) -> Double {
        length > room ? (atEnd ? room - length : 0) : Swift.min(Swift.max(start, 0), room - length)
    }
}
