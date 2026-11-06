import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportStructure.cs: document-wide decisions: which size is the body, which
// paragraphs are headings, which items form which list, which rows are running heads. The C# page number regular
// expression, ^[\-–—\s]*((page|sayfa|seite|página|pagina|strana)\s*)?\d{1,5}(\s*(of|/|von|de|di)\s*\d{1,5})?[\-–—\s]*$
// ignoring case, is matched by hand.

enum ExportStructure {
    private static let bandFraction = 0.08

    private static let pageWords = ["page", "sayfa", "seite", "página", "pagina", "strana"].map { Array($0.unicodeScalars) }
    private static let separators = ["of", "/", "von", "de", "di"].map { Array($0.unicodeScalars) }

    // Case folded as far as the words above need.
    private static func fold(_ c: Unicode.Scalar) -> Unicode.Scalar {
        if c.value >= 0x41 && c.value <= 0x5A { return Unicode.Scalar(c.value + 32) ?? c }
        return c.value == 0xC1 ? "\u{E1}" : c
    }

    private static func isPageNumber(_ text: String) -> Bool {
        let s = text.unicodeScalars.map(fold)
        var i = 0
        func rule() -> Bool { i < s.count && (s[i] == "-" || s[i] == "\u{2013}" || s[i] == "\u{2014}" || s[i].properties.isWhitespace) }
        func spaces() { while i < s.count && s[i].properties.isWhitespace { i += 1 } }
        func word(_ w: [Unicode.Scalar]) -> Bool {
            if i + w.count > s.count { return false }
            for k in 0..<w.count where s[i + k] != w[k] { return false }
            return true
        }
        // \d{1,5}, taking every digit there is: a sixth one can only fail the rest.
        func digits() -> Bool {
            var n = 0
            while i < s.count && ExportChar.isDigit(s[i]) {
                i += 1
                n += 1
            }
            return n >= 1 && n <= 5
        }

        while rule() { i += 1 }
        if let w = pageWords.first(where: { word($0) }) {
            i += w.count
            spaces()
        }
        if !digits() { return false }
        let afterNumber = i
        spaces()
        if let w = separators.first(where: { word($0) }) {
            i += w.count
            spaces()
            if !digits() { i = afterNumber }
        } else {
            i = afterNumber
        }
        while rule() { i += 1 }
        return i == s.count
    }

    static func bodySize(_ paragraphs: [ExPara]) -> Double {
        var weights = SizeWeights()
        for p in paragraphs { weights.add(p.size, p.text.utf16.count) }
        return weights.heaviest ?? 11
    }

    static func headings(_ paragraphs: [ExPara], _ body: Double) {
        let big = paragraphs.filter { $0.item == nil && $0.size >= body * 1.15 && $0.lines <= 3 && $0.text.utf16.count <= 200 }
        var sizes: [Double] = []
        var distinct: [Double] = []
        var seen = Set<Double>()
        for p in big where seen.insert(p.size).inserted { distinct.append(p.size) }
        for size in ExportSort.stable(distinct, { ExportSort.before($1, $0) }) {
            if let last = sizes.last, last - size <= 0.6 { continue }
            sizes.append(size)
        }
        for p in big { p.heading = min(6, (sizes.firstIndex { $0 - p.size <= 0.6 } ?? -1) + 1) }

        // Bold on a line of its own at body size, over a paragraph of text: a heading one level under the sized ones.
        var i = 0
        while i + 1 < paragraphs.count {
            defer { i += 1 }
            let p = paragraphs[i]
            let next = paragraphs[i + 1]
            if p.heading != 0 || p.item != nil || !p.allBold || p.lines != 1 || p.text.utf16.count > 80 || p.size < body * 0.9 || p.size >= body * 1.15 { continue }
            if let last = p.text.unicodeScalars.last, ".,;:".unicodeScalars.contains(last) { continue }
            if next.item != nil || next.allBold || next.text.utf16.count < 40 || next.size > body * 1.15 { continue }
            p.heading = min(6, sizes.count + 1)
        }
    }

    /// Runs of items in a row are a list; a new number sequence or a change between bullets and numbers starts another.
    static func lists(_ flow: [AnyObject]) -> [ExPara: ExportListItem] {
        var result: [ExPara: ExportListItem] = [:]
        var lists: [[ExPara]] = []
        var previous: ExPara?
        var lastNumber = 0
        for block in flow {
            guard let para = block as? ExPara, let item = para.item else {
                previous = nil
                continue
            }
            let before = previous?.item
            var top = false
            if let first = lists.last?.first?.item, before != nil {
                top = item.markerLeft - first.markerLeft < 6
            }
            let fresh = before == nil || item.ordered != before?.ordered || (item.ordered && top && item.number != lastNumber + 1)
            if fresh { lists.append([]) }
            lists[lists.count - 1].append(para)
            if !item.ordered || fresh || top { lastNumber = item.number }
            previous = para
        }

        for id in 0..<lists.count {
            var lefts: [Double] = []
            var distinct: [Double] = []
            var seen = Set<Double>()
            for p in lists[id] {
                if let left = p.item?.markerLeft, seen.insert(left).inserted { distinct.append(left) }
            }
            for left in ExportSort.stable(distinct, { ExportSort.before($0, $1) }) {
                if let last = lefts.last, left - last <= 6 { continue }
                lefts.append(left)
            }
            for para in lists[id] {
                guard let (ordered, number, left) = para.item else { continue }
                let level = min(3, lefts.lastIndex { $0 <= left + 6 } ?? -1)
                result[para] = ExportListItem(id + 1, ordered, max(0, level), number)
            }
        }
        return result
    }

    /// Rows in the top or bottom band of a page that are page numbers, or that repeat on at least half the pages (digits
    /// ignored), are running heads and feet.
    static func runningHeads(_ pages: [(height: Double, rows: [ExRow])]) -> Set<ExRow> {
        // Keyed by UTF-16 units: the C# compares ordinally, where String equates canonically equivalent texts.
        var seen: [[UInt16]: Int] = [:]
        var inBand: [(row: ExRow, key: [UInt16])] = []
        for (height, rows) in pages {
            var keys = Set<[UInt16]>()
            for row in rows {
                let middle = (row.top + row.bottom) / 2
                if middle > height * bandFraction && middle < height * (1 - bandFraction) { continue }
                let key = Array(ExportTrim.both(hashDigits(row.text)).lowercased().utf16)
                inBand.append((row, key))
                if keys.insert(key).inserted { seen[key, default: 0] += 1 }
            }
        }
        var dropped = Set<ExRow>()
        for (row, key) in inBand {
            let count = seen[key] ?? 0
            if isPageNumber(row.text) || (count >= 2 && count * 2 >= pages.count) { dropped.insert(row) }
        }
        return dropped
    }

    // Every run of digits (Unicode decimal digits, as \d+ takes them) becomes #.
    private static func hashDigits(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for c in text.unicodeScalars {
            if ExportChar.isDigit(c) {
                if !inRun { out.append("#") }
                inRun = true
            } else {
                out.append(c)
                inRun = false
            }
        }
        return String(out)
    }
}
