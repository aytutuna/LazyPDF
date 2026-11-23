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
        return made
    }

    /// The selected characters of a page, if the page's text is read and some of it is selected.
    public func selectedChars(on page: Int) -> LazyPDFKit.TextRange? {
        guard let text = source?.peek(page) else { return nil }
        return selected.on(page, text.chars.count)
    }

    /// Selects a run of one page's characters, as a screen reader asks to; an empty run puts the caret there.
    public func select(page: Int, _ range: LazyPDFKit.TextRange) {
        selected.set(Caret(page, range.start), Caret(page, Swift.max(range.end, range.start)))
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

    /// The character a point of the view is nearest to on a page, the caret place that a click there would take.
    public func charIndex(page: Int, at point: ViewPoint) -> Int? {
        guard let text = source?.peek(page), let matrix = pageToView(page) else { return nil }
        let shown = matrix.inverted().transform(point)
        let (x, y) = geometry(page).toUser(shown.x, shown.y)
        return text.caretAt(x, y)
    }
}
