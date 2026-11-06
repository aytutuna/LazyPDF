import Foundation

// Port of windows/LazyPDF.App/Viewer/PageHistory.cs.

/// The pages the reader jumped from, for Back and Forward. Scrolling is not a jump; a link, a bookmark or Go to page is.
public struct PageHistory {
    private static let limit = 100

    private var back: [Int] = []
    private var forward: [Int] = []

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }

    public var canGoForward: Bool { !forward.isEmpty }

    /// Notes a jump from `from` to `to`; a jump to the same page, or the forward list, is forgotten.
    public mutating func jump(_ from: Int, _ to: Int) {
        if from == to { return }
        if back.last != from { back.append(from) }
        if back.count > Self.limit { back.removeFirst() }
        forward.removeAll()
    }

    /// The page to go back to from `current`, or nil.
    public mutating func goBack(_ current: Int) -> Int? {
        guard let page = back.popLast() else { return nil }
        forward.append(current)
        return page
    }

    public mutating func goForward(_ current: Int) -> Int? {
        guard let page = forward.popLast() else { return nil }
        back.append(current)
        return page
    }

    public mutating func clear() {
        back.removeAll()
        forward.removeAll()
    }
}
