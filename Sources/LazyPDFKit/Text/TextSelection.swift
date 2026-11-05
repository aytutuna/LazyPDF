import Foundation

// Twin of windows/LazyPDF.Core/Text/TextSelection.cs: characters of a page picked by a drag, a rectangle or a click, as
// runs of indices in reading order. Points and rectangles are in user space; the viewer converts from display points
// with `PageGeometry`.

public final class TextSelection {
    private init(_ page: TextPage, _ ranges: [TextRange]) {
        self.page = page
        self.ranges = ranges
    }

    public let page: TextPage
    public let ranges: [TextRange]
    public var isEmpty: Bool { ranges.isEmpty }

    /// The characters between two insertion points, as dragging a caret from the first to the second selects them.
    /// Either order.
    public static func between(_ page: TextPage, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> TextSelection {
        let a = page.caretAt(x1, y1), b = page.caretAt(x2, y2)
        return of(page, TextRange(min(a, b), max(a, b)))
    }

    /// The characters whose boxes lie at least half inside a rectangle (a marquee), by lines in reading order.
    public static func inRectangle(_ page: TextPage, _ rect: PdfRect) -> TextSelection {
        var ranges: [TextRange] = []
        var start = -1
        for i in 0...page.chars.count {
            let inside = i < page.chars.count && covered(page.chars[i].quad, rect)
            if inside && start < 0 {
                start = i
            } else if !inside && start >= 0 {
                ranges.append(TextRange(start, i))
                start = -1
            }
        }
        return TextSelection(page, ranges)
    }

    /// The word under a point; a point on a space takes the word after it, else the one before it.
    public static func wordAt(_ page: TextPage, _ x: Double, _ y: Double) -> TextSelection {
        guard let hit = page.hitTest(x, y) else { return TextSelection(page, []) }
        let c = page.chars[hit.char]
        if c.word >= 0 { return of(page, page.wordRange(c.word)) }
        let line = page.lines[c.line].range
        for i in hit.char..<line.end where page.chars[i].word >= 0 {
            return of(page, page.wordRange(page.chars[i].word))
        }
        for i in stride(from: hit.char, through: line.start, by: -1) where page.chars[i].word >= 0 {
            return of(page, page.wordRange(page.chars[i].word))
        }
        return TextSelection(page, [])
    }

    /// The line under a point (a triple click).
    public static func lineAt(_ page: TextPage, _ x: Double, _ y: Double) -> TextSelection {
        guard let hit = page.hitTest(x, y) else { return TextSelection(page, []) }
        return of(page, page.lineRange(hit.line))
    }

    public static func of(_ page: TextPage, _ range: TextRange) -> TextSelection {
        let start = min(max(range.start, 0), page.chars.count), end = min(max(range.end, start), page.chars.count)
        return TextSelection(page, start == end ? [] : [TextRange(start, end)])
    }

    /// The selected text; runs that are not next to each other are separated by a line feed.
    public func getText(joinHyphens: Bool = false) -> String {
        ranges.map { page.getText($0, joinHyphens: joinHyphens) }.joined(separator: "\n")
    }

    /// One box per stretch of a line, for painting.
    public func quads() -> [TextQuad] {
        ranges.flatMap { page.quads($0) }
    }

    private static func covered(_ quad: TextQuad, _ rect: PdfRect) -> Bool {
        let b = quad.bounds
        if b.width <= 0 || b.height <= 0 {
            let c = quad.center
            return c.x >= rect.left && c.x <= rect.right && c.y >= rect.bottom && c.y <= rect.top
        }
        let w = min(b.right, rect.right) - max(b.left, rect.left)
        let h = min(b.top, rect.top) - max(b.bottom, rect.bottom)
        return w > 0 && h > 0 && w * h >= 0.5 * b.width * b.height
    }
}
