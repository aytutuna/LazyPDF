import Foundation
import LazyPDFKit

// What a screen reader's text element of a page asks of the viewer: the page's text with its places, the selection on the
// page, and where characters are on screen. Nothing here reads a page; a page whose text has not come answers nil.

extension ViewerModel {
    /// The text of a page, if read, with where each character stands in it.
    public func textMap(_ page: Int) -> PageTextMap? {
        guard let text = source?.peek(page) else { return nil }
        if let known = textMaps[page], known.page === text { return known }
        let made = PageTextMap(text)
        textMaps[page] = made
        // A map holds its page's text, so only the pages in view keep one once many have been asked for.
        if textMaps.count > 8 {
            let shown = Set(visiblePages)
            textMaps = textMaps.filter { shown.contains($0.key) || $0.key == page }
        }
        return made
    }

    /// The selected characters of a page, if the page's text is read and some of it is selected; the place a screen reader put
    /// its caret at counts as an empty run, until the selection changes.
    public func selectedChars(on page: Int) -> LazyPDFKit.TextRange? {
        guard let text = source?.peek(page) else { return nil }
        if let caret = readerCaret, caret.page == page {
            let at = Swift.min(caret.index, text.chars.count)
            return LazyPDFKit.TextRange(at, at)
        }
        return selected.on(page, text.chars.count)
    }

    /// Selects a run of one page's characters, as a screen reader asks to. An empty run only moves the reader's own caret and
    /// leaves what the user selected alone.
    public func select(page: Int, _ range: LazyPDFKit.TextRange) {
        // A mouse drag in progress must not overwrite what the reader just set.
        pressTicket += 1
        if range.isEmpty {
            let caret = Caret(page, range.start)
            guard readerCaret != caret else { return }
            readerCaret = caret
            onSelectionChanged?()
            return
        }
        selected.set(Caret(page, range.start), Caret(page, range.end))
        readerCaret = nil
    }

    /// The place of a run of characters in view space, nil when the page is not laid out or the run has no boxes.
    public func textBounds(page: Int, _ range: LazyPDFKit.TextRange) -> ViewRect? {
        guard let text = source?.peek(page), let matrix = pageToView(page) else { return nil }
        let area = pageBounds(page, text.quads(range))
        return area.isEmpty ? nil : PageSpace.transform(matrix, area)
    }

    /// The first and last line of a page that show in the view.
    public func visibleLines(on page: Int) -> ClosedRange<Int>? {
        guard let text = source?.peek(page), let matrix = pageToView(page) else { return nil }
        let view = ViewRect(0, 0, viewport.width, viewport.height)
        let shown = text.lines.indices.filter { line in
            let area = pageBounds(page, [text.lines[line].quad])
            return !area.isEmpty && PageSpace.transform(matrix, area).intersectsWith(view)
        }
        guard let first = shown.first, let last = shown.last else { return nil }
        return first...last
    }

    /// The character under a point of the view, or the nearest one, on a page.
    public func charIndex(page: Int, at point: ViewPoint) -> Int? {
        guard let text = source?.peek(page), let matrix = pageToView(page) else { return nil }
        let shown = matrix.inverted().transform(point)
        let (x, y) = geometry(page).toUser(shown.x, shown.y)
        return text.hitTest(x, y)?.char
    }
}
