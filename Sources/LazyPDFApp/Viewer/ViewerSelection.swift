import Foundation
import Observation
import LazyPDFKit

// Port of windows/LazyPDF.App/Viewer/ViewerSelection.cs.

/// A place between two characters: `index` characters of the page's text come before it.
public struct Caret: Comparable, Hashable {
    public let page: Int
    public let index: Int

    public init(_ page: Int, _ index: Int) {
        self.page = page
        self.index = index
    }

    public static func < (a: Caret, b: Caret) -> Bool {
        a.page != b.page ? a.page < b.page : a.index < b.index
    }
}

/// The selected text: from an anchor to a focus, across any number of pages. It holds carets only; the text of a page is
/// looked up when it is needed (`ranges`), so selecting a whole document is free.
@MainActor
@Observable
public final class ViewerSelection {
    public private(set) var anchor = Caret(0, 0)
    public private(set) var focus = Caret(0, 0)

    @ObservationIgnored public var onChanged: (() -> Void)?

    public init() {}

    public var isEmpty: Bool { anchor == focus }

    public var start: Caret { anchor < focus ? anchor : focus }

    public var end: Caret { anchor < focus ? focus : anchor }

    public func set(_ anchor: Caret, _ focus: Caret) {
        if self.anchor == anchor && self.focus == focus { return }
        self.anchor = anchor
        self.focus = focus
        onChanged?()
    }

    /// Moves the focus and keeps the anchor.
    public func extend(_ focus: Caret) {
        set(anchor, focus)
    }

    public func clear() {
        set(Caret(0, 0), Caret(0, 0))
    }

    /// Selects from the start of the first page to the end of the last (an index past the text means its end).
    public func selectAll(_ pages: Int) {
        set(Caret(0, 0), Caret(Swift.max(pages - 1, 0), Int.max))
    }

    public func covers(_ page: Int) -> Bool {
        !isEmpty && page >= start.page && page <= end.page
    }

    /// The selected stretch of one page that has `characters` characters, or nil.
    public func on(_ page: Int, _ characters: Int) -> TextRange? {
        if !covers(page) { return nil }
        let (start, end) = (start, end)
        let from = page == start.page ? Swift.min(start.index, characters) : 0
        let to = page == end.page ? Swift.min(end.index, characters) : characters
        return to > from ? TextRange(from, to) : nil
    }

    /// The stretch of each page's characters that is selected, given how many characters each page has.
    public func ranges(_ characters: (Int) -> Int) -> [(page: Int, range: TextRange)] {
        if isEmpty { return [] }
        var found: [(page: Int, range: TextRange)] = []
        for page in start.page...end.page {
            if let range = on(page, characters(page)) { found.append((page, range)) }
        }
        return found
    }
}
