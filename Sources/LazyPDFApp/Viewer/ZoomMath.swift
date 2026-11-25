import Foundation

// Port of windows/LazyPDF.App/Viewer/ZoomMath.cs: what the zoom of a view is kept to, and the zooms that fit a page to
// the window.

public enum ZoomMath {
    public static let maxZoom = 64.0

    // The scrolled area is laid out in floats on Windows; past a few million pixels a pixel is no longer exact. The
    // limit stays so a document looks the same on every platform.
    private static let maxExtent = 4_000_000.0

    private static let steps = [0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]

    /// The smallest and largest zoom for pages whose longest side is `longestSide` points.
    public static func limits(_ longestSide: Double, _ pixelsPerDip: Double) -> (min: Double, max: Double) {
        let side = Swift.max(longestSide, 1) * PageSpace.dipPerPoint
        return (Swift.min(0.05, 200 / side), Swift.min(maxZoom, maxExtent / pixelsPerDip / side))
    }

    public static func clamp(_ zoom: Double, _ limits: (min: Double, max: Double)) -> Double {
        Swift.min(Swift.max(zoom, limits.min), limits.max)
    }

    /// The zoom at which a spread `spreadWidth` points wide fills `viewport`.
    public static func fitWidth(_ spreadWidth: Double, _ viewport: ViewSize) -> Double {
        Swift.max(0, viewport.width - 2 * ViewLayout.margin) / Swift.max(spreadWidth, 1) / PageSpace.dipPerPoint
    }

    /// The zoom at which a whole spread shows in `viewport`.
    public static func fitPage(_ spread: ViewSize, _ viewport: ViewSize) -> Double {
        Swift.min(fitWidth(spread.width, viewport),
                  Swift.max(0, viewport.height - 2 * ViewLayout.margin) / Swift.max(spread.height, 1) / PageSpace.dipPerPoint)
    }

    /// The next zoom of the usual steps above or below `zoom`.
    public static func step(_ zoom: Double, _ direction: Int) -> Double {
        if direction > 0 {
            return steps.first { $0 > zoom * 1.001 } ?? steps[steps.count - 1]
        }
        return steps.last { $0 < zoom / 1.001 } ?? steps[0]
    }
}
