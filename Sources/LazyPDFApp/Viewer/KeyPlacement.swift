import Foundation

// Port of the arithmetic of windows/LazyPDF.App/Viewer/PageViewer.Placement.cs: the keyboard path for a pointer tool.
// Enter starts in the middle of the page in view, the arrow keys move the mark (small steps with Shift, big ones with
// Control or Command), and Enter again is a click there. Escape lets go, which is the owner dropping its value.

public struct KeyPlacement {
    public enum Direction {
        case left, right, up, down
    }

    public enum Pace {
        case small, normal, big

        var factor: Double {
            switch self {
            case .small: return 0.125
            case .normal: return 1
            case .big: return 5
            }
        }
    }

    private static let step = 8.0

    public let page: Int

    /// Where the click would land, in page space.
    public private(set) var point: ViewPoint

    /// Starts in the middle of the part of the current page that is in view; nil when there is none.
    public init?(_ surface: PageSurfaceState) {
        let page = surface.currentPage
        guard let matrix = surface.pageMatrix(page) else { return nil }
        let size = surface.pageSize(page)
        let shown = ViewRect.intersect(PageSpace.transform(matrix, ViewRect(0, 0, size.width, size.height)), ViewRect(0, 0, surface.viewport.width, surface.viewport.height))
        if shown.isEmpty { return nil }
        guard let found = surface.hit(shown.center) else { return nil }
        self.page = found.page
        point = found.point
    }

    /// Moves the mark, kept on the page. False when the page is no longer laid out.
    public mutating func move(_ direction: Direction, _ pace: Pace, _ surface: PageSurfaceState) -> Bool {
        guard let matrix = surface.pageMatrix(page) else { return false }
        let step = Self.step * pace.factor
        let at = matrix.transform(point)
        let moved: ViewPoint
        switch direction {
        case .left: moved = ViewPoint(at.x - step, at.y)
        case .right: moved = ViewPoint(at.x + step, at.y)
        case .up: moved = ViewPoint(at.x, at.y - step)
        case .down: moved = ViewPoint(at.x, at.y + step)
        }
        let back = matrix.inverted().transform(moved)
        let size = surface.pageSize(page)
        point = ViewPoint(Swift.min(Swift.max(back.x, 0), size.width), Swift.min(Swift.max(back.y, 0), size.height))
        return true
    }
}
