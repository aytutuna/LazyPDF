import Foundation

/// The accessibility element of each page in view, kept between queries so a screen reader meets the same object again and a
/// notification posted on it reaches it. It starts over when the model's text epoch moves.
@MainActor
public struct PageElementCache<Element: AnyObject> {
    private var kept: [Int: Element] = [:]
    private var epoch = -1

    public init() {}

    /// The elements of `pages` in that order; pages that went out of view are let go.
    public mutating func elements(for pages: [Int], epoch: Int, make: (Int) -> Element?) -> [Element] {
        if epoch != self.epoch {
            kept.removeAll()
            self.epoch = epoch
        }
        let wanted = Set(pages)
        kept = kept.filter { wanted.contains($0.key) }
        return pages.compactMap { page in
            if let known = kept[page] { return known }
            guard let made = make(page) else { return nil }
            kept[page] = made
            return made
        }
    }

    /// The element of a page if one has been handed out.
    public func element(for page: Int) -> Element? { kept[page] }
}
