import Foundation

// Port of windows/LazyPDF.App/Viewer/PageHistory.cs.

/// The places the reader jumped from, for Back and Forward. Scrolling is not a jump; a link, a bookmark or Go to page is.
public struct PageHistory {
    private static let limit = 100

    private var back: [PagePoint] = []
    private var forward: [PagePoint] = []

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }

    public var canGoForward: Bool { !forward.isEmpty }

    /// Notes a jump from `from` to `to` and forgets the forward list. False, and nothing noted, when `to` is on the same page within 50 points.
    @discardableResult
    public mutating func jump(_ from: PagePoint, _ to: PagePoint) -> Bool {
        if from.page == to.page && abs(from.point.y - to.point.y) < 50 { return false }
        back.append(from)
        if back.count > Self.limit { back.removeFirst() }
        forward.removeAll()
        return true
    }

    /// The place to go back to from `current`, or nil.
    public mutating func goBack(_ current: PagePoint) -> PagePoint? {
        guard let place = back.popLast() else { return nil }
        forward.append(current)
        return place
    }

    public mutating func goForward(_ current: PagePoint) -> PagePoint? {
        guard let place = forward.popLast() else { return nil }
        back.append(current)
        return place
    }

    public mutating func clear() {
        back.removeAll()
        forward.removeAll()
    }
}
