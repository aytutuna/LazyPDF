import Foundation

/// What a finished tab drag leaves to do, as OutcomeOf in windows/LazyPDF.App/MainWindow.Tabs.cs decides it.
public enum TabDrag {
    /// Farther than this from the strip, in points, a drag that nobody took opens a window.
    public static let tearOutDistance: CGFloat = 60

    /// A drag nobody took opens a window when it ends far from the strip, wherever that is: a maximized or full-screen window
    /// covers its whole screen, so 'outside every window' would never hold. Escape cancels it. `point` and `strip` share one
    /// coordinate space.
    public static func tearsOut(taken: Bool, escaped: Bool, at point: CGPoint, strip: CGRect,
                                distance: CGFloat = tearOutDistance) -> Bool {
        if taken || escaped { return false }
        return point.x < strip.minX - distance || point.x > strip.maxX + distance
            || point.y < strip.minY - distance || point.y > strip.maxY + distance
    }
}
