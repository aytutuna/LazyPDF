import Foundation

// Twin of windows/LazyPDF.Core/Ocr/OcrText.cs, from Lazy Scan's OcrText. Boxes are pixels with the origin top-left
// here, so nothing is flipped or scaled, and the input is words that are first joined into lines.

/// A line of recognized text: the words on one row, left to right, with the box around them.
public struct OcrLine {
    public let text: String
    public let box: OcrBox
    public let confidence: Float
    public let words: [OcrWord]

    public init(_ text: String, _ box: OcrBox, _ confidence: Float, _ words: [OcrWord]) {
        self.text = text
        self.box = box
        self.confidence = confidence
        self.words = words
    }

    public static func of(_ word: OcrWord) -> OcrLine { OcrLine(word.text, word.box, word.confidence, [word]) }
}

/// The recognized lines of one page, in reading order, and the page's size in the same unit as the boxes.
public struct OcrPage {
    public let lines: [OcrLine]
    public let width: Double
    public let height: Double

    public init(_ lines: [OcrLine], _ width: Double, _ height: Double) {
        self.lines = lines
        self.width = width
        self.height = height
    }

    public static func of(_ words: [OcrWord], _ pixelWidth: Int, _ pixelHeight: Int) -> OcrPage {
        OcrPage(OcrText.lines(words), Double(pixelWidth), Double(pixelHeight))
    }
}

/// Lines of text that belong together.
public struct OcrParagraph {
    public let lines: [OcrLine]
    public let pageWidth: Double

    public init(_ lines: [OcrLine], _ pageWidth: Double) {
        self.lines = lines
        self.pageWidth = pageWidth
    }

    public var text: String { OcrText.paragraphText(lines, pageWidth) }
}

/// Turns the words an OCR engine found into lines in reading order, and into paragraphs.
///
/// Reading order: the page is cut along an empty gap, across or down, again and again (a recursive X-Y cut): along the
/// widest gap across the page when it is at least `blockGap` line heights tall, else along the widest gap down the page
/// when it is at least `columnGap` line heights wide and both sides are columns of two items or more, else along any gap
/// across the page. Two sides that share their rows are a table and are read row by row. Items on one row become one
/// line, a tab across a wide gap.
///
/// Paragraphs: a new one starts where the text jumps up, where the gap above a line is clearly wider than the usual one,
/// where the left edge moves by a fifth of the page, and where a line is indented. Lines centred on each other are
/// neither indented nor moved.
public enum OcrText {
    public static let columnGap = 2.0
    public static let blockGap = 1.5
    public static let tableGapShare = 1.0
    public static let sameRowOverlap = 0.5
    public static let paragraphGap = 0.75
    public static let paragraphGapFactor = 1.5
    public static let indentLines = 1.0
    public static let leftEdgeShift = 0.2
    /// A line ending this share of the page width before the paragraph's longest line keeps its line break.
    public static let shortLineShare = 0.15
    public static let centredLines = 0.25
    public static let jumpLines = 0.5
    public static let cellSeparator = "\t"

    private static let maxDepth = 200

    /// The words as lines in reading order.
    public static func lines(_ words: [OcrWord]) -> [OcrLine] { readingOrder(words.map(OcrLine.of)) }

    /// The lines in reading order. Lines of one row become one line (its box is theirs together, its confidence their
    /// lowest); empty lines and empty boxes are dropped.
    public static func readingOrder(_ lines: [OcrLine]) -> [OcrLine] {
        var items: [Item] = []
        for line in lines {
            let text = cleanLine(line.text)
            let box = line.box
            if text.isEmpty || !(box.width > 0) || !(box.height > 0) { continue }
            let cleaned = OcrLine(text, box, line.confidence, line.words)
            items.append(Item(line: cleaned, index: items.count, left: box.x, top: box.y, right: box.right, bottom: box.bottom))
        }
        var output: [OcrLine] = []
        cut(items, &output, 0)
        return output
    }

    public static func paragraphs(_ page: OcrPage) -> [OcrParagraph] { paragraphs(readingOrder(page.lines), page.width) }

    /// `ordered` (as `readingOrder` returns it) split into paragraphs.
    public static func paragraphs(_ ordered: [OcrLine], _ pageWidth: Double) -> [OcrParagraph] {
        var items: [Item] = []
        for line in ordered {
            items.append(Item(line: line, index: items.count, left: line.box.x, top: line.box.y, right: line.box.right, bottom: line.box.bottom))
        }
        var paragraphs: [OcrParagraph] = []
        guard let first = items.first else { return paragraphs }

        let lineHeight = median(items.map { $0.height })
        // gaps[i] runs from line i - 1 down to line i.
        var gaps = [Double](repeating: 0, count: items.count)
        for i in 1..<max(items.count, 1) { gaps[i] = items[i].top - items[i - 1].bottom }
        let positive = gaps.dropFirst().filter { $0 > 0 }
        let pageGap = positive.isEmpty ? 0 : median(positive)

        var current = [first.line]
        for i in 1..<max(items.count, 1) {
            let previous = items[i - 1]
            let item = items[i]
            // A page of short paragraphs has a median gap as wide as a break, so the gaps next to this one count too.
            var usualGap = pageGap
            if i > 1 && gaps[i - 1] > 0 { usualGap = nanMin(usualGap, gaps[i - 1]) }
            if i + 1 < items.count && gaps[i + 1] > 0 { usualGap = nanMin(usualGap, gaps[i + 1]) }
            let breakGap = nanMax(paragraphGap * lineHeight, paragraphGapFactor * usualGap)
            let centred = abs((item.left + item.right) - (previous.left + previous.right)) / 2 <= centredLines * lineHeight
            let starts = item.top < previous.top - jumpLines * lineHeight
                || gaps[i] > breakGap
                || (!centred && abs(item.left - previous.left) > leftEdgeShift * pageWidth)
                || (!centred && item.left - previous.left > indentLines * lineHeight)
            if starts {
                paragraphs.append(OcrParagraph(current, pageWidth))
                current = []
            }
            current.append(item.line)
        }
        paragraphs.append(OcrParagraph(current, pageWidth))
        return paragraphs
    }

    /// A paragraph as text: a line that reaches to within `shortLineShare` of the page width of the longest one wraps into
    /// the next with a space, or without the hyphen of a broken word; a short line and a table row keep their line break.
    public static func paragraphText(_ lines: [OcrLine], _ pageWidth: Double) -> String {
        if lines.isEmpty { return "" }
        let right = maximum(lines.map { $0.box.right })
        var sb: [UInt16] = []
        var previous: [UInt16]?
        var previousRight = 0.0
        for line in lines {
            let text = trimmed(Array(line.text.utf16))
            if text.isEmpty { continue }
            if let before = previous {
                if before.contains(9) || text.contains(9) || previousRight < right - shortLineShare * pageWidth {
                    sb.append(10)
                    sb += text
                } else if sb.count >= 2 && sb[sb.count - 1] == 0x2D && sb[sb.count - 2].isLetter && text[0].isLower {
                    sb.removeLast()
                    sb += text
                } else {
                    sb.append(0x20)
                    sb += text
                }
            } else {
                sb += text
            }
            previous = text
            previousRight = line.box.right
        }
        return String(units: sb)
    }

    /// One line of text per line on the page, a blank line between paragraphs; empty when nothing was recognized.
    public static func pageText(_ page: OcrPage) -> String {
        paragraphs(page).map { $0.lines.map { $0.text }.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// Pages joined by two blank lines, a line break at the end; empty when no page has text.
    public static func plainText(_ pages: [OcrPage]) -> String {
        let texts = pages.map(pageText)
        if texts.allSatisfy({ $0.isEmpty }) { return "" }
        return texts.joined(separator: "\n\n\n") + "\n"
    }

    /// Control characters become spaces (a tab stays), runs of spaces one space, none at either end.
    public static func cleanLine(_ text: String) -> String {
        var cleaned: [UInt16] = []
        for c in text.utf16 {
            let unit: UInt16
            if c == 9 {
                unit = c
            } else if c < 0x20 || (c >= 0x7F && c <= 0x9F) || c == 0x2028 || c == 0x2029 {
                unit = 0x20
            } else {
                unit = c
            }
            if unit == 0x20 && (cleaned.isEmpty || cleaned[cleaned.count - 1] == 0x20) { continue }
            cleaned.append(unit)
        }
        while let last = cleaned.last, last == 0x20 || last == 9 { cleaned.removeLast() }
        var start = 0
        while start < cleaned.count && (cleaned[start] == 0x20 || cleaned[start] == 9) { start += 1 }
        return String(units: Array(cleaned[start...]))
    }

    private struct Item {
        let line: OcrLine
        let index: Int
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double

        var height: Double { bottom - top }
    }

    /// What `cut` does with a set of items: the one row they make, rows to read one by one, or two halves.
    private enum Step {
        case row
        case rows([Item])
        case splitTop([Item], Int)
        case splitLeft([Item], [Item])
    }

    // The recursive part only switches; the work of choosing is in `plan`.
    private static func cut(_ items: [Item], _ output: inout [OcrLine], _ depth: Int) {
        guard let step = plan(items, depth) else { return }
        switch step {
        case .row:
            output.append(joinRow(items))
        case .rows(let byTop):
            for row in rows(byTop) { output.append(joinRow(row)) }
        case .splitTop(let byTop, let at):
            cut(Array(byTop[..<at]), &output, depth + 1)
            cut(Array(byTop[at...]), &output, depth + 1)
        case .splitLeft(let left, let right):
            cut(left, &output, depth + 1)
            cut(right, &output, depth + 1)
        }
    }

    private static func plan(_ items: [Item], _ depth: Int) -> Step? {
        if items.isEmpty { return nil }
        if items.count == 1 || isOneRow(items) { return .row }
        let byTop = items.sorted { a, b in
            let t = compareDoubles(a.top, b.top)
            if t != 0 { return t < 0 }
            let l = compareDoubles(a.left, b.left)
            if l != 0 { return l < 0 }
            return a.index < b.index
        }
        if depth >= maxDepth { return .rows(byTop) }
        let lineHeight = median(items.map { $0.height })

        let (gapY, splitY) = widestGap(byTop, { $0.top }, { $0.bottom })
        let byLeft = items.sorted { a, b in
            let l = compareDoubles(a.left, b.left)
            if l != 0 { return l < 0 }
            let t = compareDoubles(a.top, b.top)
            if t != 0 { return t < 0 }
            return a.index < b.index
        }
        let (gapX, splitX) = widestGap(byLeft, { $0.left }, { $0.right })

        if gapY >= blockGap * lineHeight { return .splitTop(byTop, splitY) }
        if gapX >= columnGap * lineHeight {
            let left = Array(byLeft[..<splitX])
            let right = Array(byLeft[splitX...])
            // A lone item on one side is a heading's neighbour or a cell, not a column.
            if left.count >= 2 && right.count >= 2 && !isTable(left, right, gapX) { return .splitLeft(left, right) }
        }
        if gapY > 0 { return .splitTop(byTop, splitY) }

        // No gap across the page: rows that touch, or a slanted page.
        return .rows(byTop)
    }

    /// The widest empty gap along one axis of `sorted` and the index of the first item after it; (0, 0) when the items
    /// overlap throughout.
    private static func widestGap(_ sorted: [Item], _ start: (Item) -> Double, _ end: (Item) -> Double) -> (gap: Double, split: Int) {
        var best = 0.0
        var split = 0
        var reach = sorted.first.map(end) ?? 0
        for i in 1..<max(sorted.count, 1) {
            let gap = start(sorted[i]) - reach
            if gap > best {
                best = gap
                split = i
            }
            reach = nanMax(reach, end(sorted[i]))
        }
        return (best, split)
    }

    /// More than half the items on each side share their row with one on the other, and the gap is at least
    /// `tableGapShare` of the narrower side's typical width: a table, not two columns.
    private static func isTable(_ left: [Item], _ right: [Item], _ gap: Double) -> Bool {
        func mostlyPaired(_ side: [Item], _ other: [Item]) -> Bool {
            2 * side.filter { item in other.contains { sameRow(item, $0) } }.count > side.count
        }
        let narrower = nanMin(median(left.map { $0.right - $0.left }), median(right.map { $0.right - $0.left }))
        return mostlyPaired(left, right) && mostlyPaired(right, left) && gap >= tableGapShare * narrower
    }

    private static func sameRow(_ a: Item, _ b: Item) -> Bool {
        nanMin(a.bottom, b.bottom) - nanMax(a.top, b.top) >= sameRowOverlap * nanMin(a.height, b.height)
    }

    private static func isOneRow(_ items: [Item]) -> Bool {
        let top = maximum(items.map { $0.top })
        let bottom = minimum(items.map { $0.bottom })
        let lowest = minimum(items.map { $0.height })
        return bottom - top >= sameRowOverlap * lowest
    }

    private static func rows(_ byTop: [Item]) -> [[Item]] {
        var rows: [[Item]] = []
        for item in byTop {
            let home = rows.firstIndex { row in
                row.allSatisfy { other in sameRow(other, item) && (item.right <= other.left || item.left >= other.right) }
            }
            if let home { rows[home].append(item) } else { rows.append([item]) }
        }
        return rows
            .map { (top: minimum($0.map { $0.top }), index: $0[0].index, row: $0) }
            .sorted { a, b in
                let t = compareDoubles(a.top, b.top)
                return t != 0 ? t < 0 : a.index < b.index
            }
            .map { $0.row }
    }

    private static func joinRow(_ row: [Item]) -> OcrLine {
        if row.count == 1 { return row[0].line }
        let sorted = row.sorted { a, b in
            let l = compareDoubles(a.left, b.left)
            return l != 0 ? l < 0 : a.index < b.index
        }
        let lineHeight = median(sorted.map { $0.height })
        var text = sorted[0].line.text
        var reach = sorted[0].right
        for item in sorted.dropFirst() {
            text += item.left - reach >= columnGap * lineHeight ? cellSeparator : " "
            text += item.line.text
            reach = nanMax(reach, item.right)
        }
        let left = minimum(sorted.map { $0.left })
        let top = minimum(sorted.map { $0.top })
        let box = OcrBox(left, top, maximum(sorted.map { $0.right }) - left, maximum(sorted.map { $0.bottom }) - top)
        return OcrLine(text, box, minimum(sorted.map { $0.line.confidence }), sorted.flatMap { $0.line.words })
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted { compareDoubles($0, $1) < 0 }
        if sorted.isEmpty { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    // Enumerable.Max and Enumerable.Min of doubles: Max skips a NaN, Min is NaN when any item is. Never called on an empty list.
    private static func maximum<T: BinaryFloatingPoint>(_ values: [T]) -> T {
        var value = T.nan
        for x in values where !x.isNaN {
            if value.isNaN || x > value { value = x }
        }
        return value
    }

    private static func minimum<T: BinaryFloatingPoint>(_ values: [T]) -> T {
        guard var value = values.first else { return T.nan }
        for x in values.dropFirst() {
            if value.isNaN { break }
            if x < value { value = x } else if x.isNaN { value = x }
        }
        return value
    }

    private static func trimmed(_ units: [UInt16]) -> [UInt16] {
        var start = 0
        var end = units.count
        while start < end && units[start].isWhiteSpace { start += 1 }
        while end > start && units[end - 1].isWhiteSpace { end -= 1 }
        return Array(units[start..<end])
    }
}
