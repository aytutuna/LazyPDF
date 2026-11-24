import Foundation
import LazyPDFKit

/// The text of a page for a screen reader, with the place of every character in it, so a reader that speaks in UTF-16 offsets
/// of that string can be answered in characters and lines of the page and the other way round. Unlike `TextPage.text`, a line
/// always starts after a break, also when it starts with a space, and a soft hyphen is never kept, so words from two lines are
/// never read as one. Characters the text leaves out (spaces at the edges of a line, glyphs with no text, soft hyphens) stand
/// where the next kept one starts; the break before a line belongs to no character.
public final class PageTextMap {
    public let page: TextPage
    private let units: [UInt16]
    private var starts: [Int]
    private var ends: [Int]

    /// The length of the text in UTF-16 units.
    public var length: Int { units.count }

    public var text: String { String(decoding: units, as: UTF16.self) }

    public var lineCount: Int { ends.count }

    public init(_ page: TextPage) {
        self.page = page
        let chars = page.chars
        var sb: [UInt16] = []
        var pending: [UInt16] = []
        var spaces: [Int] = []
        var waiting: [Int] = []
        var offsets = [Int](repeating: 0, count: chars.count + 1)
        var lineEnds = [Int](repeating: 0, count: page.lines.count)
        var line = -1
        var atStart = true

        func settle() {
            for i in spaces { offsets[i] = sb.count }
            spaces.removeAll()
            pending.removeAll(keepingCapacity: true)
        }

        for i in 0..<chars.count {
            let c = chars[i]
            if c.line != line {
                if line >= 0 && line < lineEnds.count { lineEnds[line] = sb.count }
                settle()
                line = c.line
                atStart = true
            }
            if c.isSpace {
                if atStart {
                    waiting.append(i)
                } else {
                    spaces.append(i)
                    offsets[i] = sb.count + pending.count
                    pending.append(contentsOf: c.text.utf16)
                }
                continue
            }
            if c.text.isEmpty || c.text == "\u{AD}" {
                waiting.append(i)
                continue
            }
            if atStart && !sb.isEmpty {
                sb.append(contentsOf: Self.separator(page.lines[line].before))
            }
            sb.append(contentsOf: pending)
            spaces.removeAll()
            pending.removeAll(keepingCapacity: true)
            for w in waiting { offsets[w] = sb.count }
            waiting.removeAll()
            offsets[i] = sb.count
            sb.append(contentsOf: c.text.utf16)
            atStart = false
        }
        if line >= 0 && line < lineEnds.count { lineEnds[line] = sb.count }
        settle()
        for w in waiting { offsets[w] = sb.count }
        offsets[chars.count] = sb.count
        // A dropped glyph never stands past the one after it.
        var i = chars.count - 1
        while i >= 0 {
            offsets[i] = Swift.min(offsets[i], offsets[i + 1])
            i -= 1
        }
        units = sb
        starts = offsets
        ends = lineEnds
    }

    private static func separator(_ before: TextBreak) -> [UInt16] {
        switch before {
        case .tab: return [0x09]
        case .line: return [0x0A]
        case .block: return [0x0A, 0x0A]
        case .none: return []
        }
    }

    /// Where a character starts in the text.
    public func offset(ofChar index: Int) -> Int {
        starts[Swift.min(Swift.max(index, 0), starts.count - 1)]
    }

    /// The units of a character: its own text, none for one the text leaves out.
    public func units(ofChar index: Int) -> Range<Int> {
        guard index >= 0 && index < page.chars.count else { return length..<length }
        let from = offset(ofChar: index)
        return from..<Swift.min(from + page.chars[index].text.utf16.count, offset(ofChar: index + 1))
    }

    /// The character a unit belongs to; a ligature's units all give the same one. A unit at the end gives the character count.
    public func char(atOffset offset: Int) -> Int {
        let count = page.chars.count
        if offset >= units.count { return count }
        // The last character that starts at or before the offset, so a dropped glyph before a kept one does not take its place.
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return Swift.max(low - 1, 0)
    }

    /// The characters that a stretch of units touches, widened to whole characters.
    public func chars(in range: Range<Int>) -> LazyPDFKit.TextRange {
        let from = char(atOffset: range.lowerBound)
        if range.isEmpty { return LazyPDFKit.TextRange(from, from) }
        let last = char(atOffset: range.upperBound - 1)
        return LazyPDFKit.TextRange(from, Swift.min(last + 1, page.chars.count))
    }

    /// The units that a run of characters covers.
    public func units(of range: LazyPDFKit.TextRange) -> Range<Int> {
        let from = offset(ofChar: range.start)
        let to = Swift.max(offset(ofChar: range.end), from)
        return from..<to
    }

    public func string(in range: Range<Int>) -> String {
        let low = Swift.min(Swift.max(range.lowerBound, 0), units.count)
        let high = Swift.min(Swift.max(range.upperBound, low), units.count)
        return String(decoding: units[low..<high], as: UTF16.self)
    }

    /// The units of a line's own text, without the break before it.
    public func units(ofLine line: Int) -> Range<Int> {
        guard line >= 0 && line < ends.count else { return length..<length }
        let from = offset(ofChar: page.lines[line].range.start)
        return from..<Swift.max(ends[line], from)
    }

    /// The line a unit is on: the last one that starts at or before it, and the first for a unit before them all.
    public func line(atOffset offset: Int) -> Int {
        var low = 0, high = ends.count
        while low < high {
            let middle = (low + high) / 2
            if units(ofLine: middle).lowerBound <= offset { low = middle + 1 } else { high = middle }
        }
        return Swift.max(low - 1, 0)
    }
}
