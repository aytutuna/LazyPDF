import Foundation

// Twin of windows/LazyPDF.Core/Text/TextPage.Hit.cs: the character nearest to a point, and the caret.

extension TextPage {
    /// The character nearest to a point in user space, with its word and line; nil when the page has no text or the
    /// nearest one is farther than `maxDistance` (user space units). A point inside a character's box has distance 0.
    public func hitTest(_ x: Double, _ y: Double, maxDistance: Double = Double.infinity) -> TextHit? {
        let (line, lineDistance) = nearestLine(x, y)
        if line < 0 || lineDistance > maxDistance { return nil }
        let (index, distance) = nearestChar(line, x, y)
        if index < 0 || distance > maxDistance { return nil }
        let c = chars[index]
        return TextHit(char: index, word: c.word, line: c.line, distance: distance)
    }

    /// The insertion point nearest to a point, as a character index from 0 to `chars.count`: the gap before that
    /// character. Used with a second one it gives a selection like a text caret does.
    public func caretAt(_ x: Double, _ y: Double) -> Int {
        let (line, _) = nearestLine(x, y)
        if line < 0 { return 0 }
        let (top, bottom) = extent()
        let shown = geometry.toDisplay(x, y).y
        if shown < top { return 0 }
        if shown > bottom { return chars.count }
        let (index, _) = nearestChar(line, x, y)
        if index < 0 { return lines[line].range.start }
        let c = chars[index]
        let center = c.quad.center
        let axis = Self.readingAxis(lines[line])
        let along = (x - center.x) * axis.x + (y - center.y) * axis.y
        return (c.isRtl ? along < 0 : along > 0) ? index + 1 : index
    }

    // The vertical extent of the text as shown, so that a point above it or below it can be told from one beside it.
    private func extent() -> (top: Double, bottom: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let known = extentKnown { return known }
        var top = Double.greatestFiniteMagnitude, bottom = -Double.greatestFiniteMagnitude
        for line in lines {
            let r = geometry.toDisplay(line.bounds)
            top = min(top, r.y)
            bottom = max(bottom, r.y + r.height)
        }
        extentKnown = (top, bottom)
        return (top, bottom)
    }

    // The direction a line is read in, in user space.
    private static func readingAxis(_ line: PageLine) -> (x: Double, y: Double) {
        let q = line.quad
        let x = line.isVertical ? q.x0 - q.x3 : q.x1 - q.x0, y = line.isVertical ? q.y0 - q.y3 : q.y1 - q.y0
        let length = (x * x + y * y).squareRoot()
        return length < 1e-12 ? (1, 0) : (x / length, y / length)
    }

    private func nearestLine(_ x: Double, _ y: Double) -> (index: Int, distance: Double) {
        var best = -1
        var distance = Double.greatestFiniteMagnitude
        for i in 0..<lines.count {
            let b = lines[i].bounds
            let dx = max(max(b.left - x, x - b.right), 0), dy = max(max(b.bottom - y, y - b.top), 0)
            if (dx * dx + dy * dy).squareRoot() - 1e-9 > distance { continue }
            let d = lines[i].quad.distanceTo(x, y)
            if d < distance {
                distance = d
                best = i
            }
        }
        return (best, distance)
    }

    private func nearestChar(_ line: Int, _ x: Double, _ y: Double) -> (index: Int, distance: Double) {
        var best = -1
        var distance = Double.greatestFiniteMagnitude
        let range = lines[line].range
        for i in range.start..<range.end {
            let d = chars[i].quad.distanceTo(x, y)
            if d < distance || (d == distance && best >= 0 && chars[best].isSpace && !chars[i].isSpace) {
                distance = d
                best = i
            }
        }
        return (best, distance)
    }
}
