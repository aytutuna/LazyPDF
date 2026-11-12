import Foundation

// Twin of windows/LazyPDF.Core/Office/Docx/DocxNumbering.cs: the lists of word/numbering.xml.

/// What a list paragraph gets in front of its text, and the level's own paragraph and run formatting.
struct NumberLabel {
    let text: String
    let suffix: String
    let pPr: OfficeXmlElement?
    let rPr: OfficeXmlElement?
    let symbolFont: String?
    let tabStop: Double?
}

/// Counters run in document order: a `w:num` that restarts a level counts for itself, every other one counts with the
/// nums of its `w:abstractNum`, as in Word.
final class DocxNumbering {
    private static let levels = 9
    private static let maxDefinitions = 10000
    private static let maxValue = 32767
    private static let maxLabel = 64

    private final class Level {
        var format = "decimal"
        var text = ""
        var start = 1
        var restart: Int?
        var legal = false
        var suffix = "tab"
        var style: String?
        var pPr: OfficeXmlElement?
        var rPr: OfficeXmlElement?
    }

    private final class Num {
        var abstract = 0
        var replaced = [Level?](repeating: nil, count: DocxNumbering.levels)
        var starts = [Int?](repeating: nil, count: DocxNumbering.levels)
        var restarts = false
    }

    private final class Counters {
        var value = [Int](repeating: 0, count: DocxNumbering.levels)
        var seen = [Bool](repeating: false, count: DocxNumbering.levels)
    }

    private struct CounterKey: Hashable {
        let own: Bool
        let id: Int
    }

    private var abstracts: [Int: [Level?]] = [:]
    private var nums: [Int: Num] = [:]
    private var counters: [CounterKey: Counters] = [:]

    static func read(_ root: OfficeXmlElement?) -> DocxNumbering {
        let numbering = DocxNumbering()
        guard let root else { return numbering }
        let w = DocxReader.w
        for a in root.elements(w, "abstractNum") {
            if numbering.abstracts.count >= maxDefinitions { break }
            guard let id = id(a, "abstractNumId"), numbering.abstracts[id] == nil else { continue }
            var found = [Level?](repeating: nil, count: levels)
            for l in a.elements(w, "lvl") {
                if let read = readLevel(l) { found[read.index] = read.level }
            }
            numbering.abstracts[id] = found
        }
        for n in root.elements(w, "num") {
            if numbering.nums.count >= maxDefinitions { break }
            guard let id = id(n, "numId"), numbering.nums[id] == nil else { continue }
            guard let target = Self.id(n.child(w, "abstractNumId") ?? n, "val") else { continue }
            let num = Num()
            num.abstract = target
            for o in n.elements(w, "lvlOverride") {
                guard let at = DocxReader.number(o.attribute(w, "ilvl")), at >= 0, at < Double(levels) else { continue }
                let index = Int(at)
                if let start = DocxReader.number(o.child(w, "startOverride")?.attribute(w, "val")) {
                    num.starts[index] = clamp(start)
                    num.restarts = true
                }
                if let replacement = o.child(w, "lvl"), let read = readLevel(replacement) { num.replaced[index] = read.level }
            }
            numbering.nums[id] = num
        }
        return numbering
    }

    private static func id(_ e: OfficeXmlElement, _ name: String) -> Int? {
        guard let v = DocxReader.number(e.attribute(DocxReader.w, name)) else { return nil }
        return Int(min(max(v, -2147483648), 2147483647))
    }

    private static func clamp(_ v: Double) -> Int { Int(min(max(v, 0), Double(maxValue))) }

    private static func readLevel(_ l: OfficeXmlElement) -> (index: Int, level: Level)? {
        let w = DocxReader.w
        guard let at = DocxReader.number(l.attribute(w, "ilvl")), at >= 0, at < Double(levels) else { return nil }
        let level = Level()
        level.format = l.child(w, "numFmt")?.attribute(w, "val") ?? "decimal"
        level.text = l.child(w, "lvlText")?.attribute(w, "val") ?? ""
        if let s = DocxReader.number(l.child(w, "start")?.attribute(w, "val")) { level.start = clamp(s) }
        if let r = DocxReader.number(l.child(w, "lvlRestart")?.attribute(w, "val")) { level.restart = clamp(r) }
        if let legal = l.child(w, "isLgl") { level.legal = DocxReader.on(legal) }
        level.suffix = l.child(w, "suff")?.attribute(w, "val") ?? "tab"
        level.style = l.child(w, "pStyle")?.attribute(w, "val")
        level.pPr = l.child(w, "pPr")
        level.rPr = l.child(w, "rPr")
        return (Int(at), level)
    }

    private func find(_ num: Num, _ index: Int) -> Level? {
        num.replaced[index] ?? abstracts[num.abstract]?[index]
    }

    /// The label of the next item of list `numId`, or nil when there is no such list or level, so the paragraph stays
    /// plain. Without `level` the level linked to the paragraph's style is used, else the first.
    func next(_ numId: Int, _ level: Int?, _ styleId: String?) -> NumberLabel? {
        let levels = Self.levels
        guard let num = nums[numId], abstracts[num.abstract] != nil else { return nil }
        let at = level.map { min(max($0, 0), levels - 1) } ?? linked(num, styleId)
        guard let current = find(num, at) else { return nil }

        let key = CounterKey(own: num.restarts, id: num.restarts ? numId : num.abstract)
        let state: Counters
        if let known = counters[key] {
            state = known
        } else {
            state = Counters()
            counters[key] = state
        }
        for k in (at + 1)..<levels {
            // A level starts over after a higher one, or after the level lvlRestart names (1 based); 0 means never.
            let after = find(num, k)?.restart ?? k
            if after > at { state.seen[k] = false }
        }
        state.value[at] = state.seen[at] ? min(state.value[at] + 1, Self.maxValue) : startOf(num, current, at)
        state.seen[at] = true

        var text: [UInt16] = []
        let pattern = Array(current.text.utf16)
        var i = 0
        while i < pattern.count && text.count < Self.maxLabel {
            if pattern[i] == 0x25 && i + 1 < pattern.count && pattern[i + 1] >= 0x31 && pattern[i + 1] <= 0x39 {
                i += 1
                let referenced = Int(pattern[i]) - 0x31
                let other = find(num, referenced)
                let value = state.seen[referenced] ? state.value[referenced] : startOf(num, other, referenced)
                text.append(contentsOf: Self.format(value, current.legal && referenced != at ? "decimal" : other?.format ?? "decimal").utf16)
            } else {
                text.append(pattern[i])
            }
            i += 1
        }

        if text.count > Self.maxLabel { text.removeSubrange(Self.maxLabel...) }
        var result = String(decoding: text, as: UTF16.self)
        var symbol: String?
        if current.format == "bullet" {
            symbol = Self.symbolFont(current.rPr)
            result = text.isEmpty ? "\u{2022}" : Self.bullet(text, symbol)
        }
        return NumberLabel(text: result, suffix: current.suffix, pPr: current.pPr, rPr: current.rPr, symbolFont: symbol, tabStop: Self.tabStop(current.pPr))
    }

    private func linked(_ num: Num, _ styleId: String?) -> Int {
        guard let styleId else { return 0 }
        for k in 0..<Self.levels where find(num, k)?.style == styleId { return k }
        return 0
    }

    private func startOf(_ num: Num, _ level: Level?, _ at: Int) -> Int { num.starts[at] ?? level?.start ?? 1 }

    // The first explicit stop of the level, in points; "clear" stops do not count.
    private static func tabStop(_ pPr: OfficeXmlElement?) -> Double? {
        let w = DocxReader.w
        for tab in pPr?.child(w, "tabs")?.elements(w, "tab") ?? [] {
            let kind = tab.attribute(w, "val")
            if kind == "clear" || kind == "bar" || kind == "num" { continue }
            if let pos = DocxReader.number(tab.attribute(w, "pos")) { return min(max(pos / 20, 0), 1584) }
        }
        return nil
    }

    private static func symbolFont(_ rPr: OfficeXmlElement?) -> String? {
        guard let name = rPr?.child(DocxReader.w, "rFonts")?.attribute(DocxReader.w, "ascii") else { return nil }
        let folded = String(decoding: name.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }, as: UTF8.self)
        return folded == "symbol" || folded == "wingdings" || folded == "webdings" ? name : nil
    }

    // Symbol fonts keep their bullets in the private use area, which no text font draws.
    private static func bullet(_ text: [UInt16], _ symbolFont: String?) -> String {
        if symbolFont == nil { return String(decoding: text, as: UTF16.self) }
        var o: [UInt16] = []
        for c in text {
            if c & 0xFF00 != 0xF000 {
                o.append(c)
                continue
            }
            o.append(symbolBullet(Int(c & 0xFF)))
        }
        return String(decoding: o, as: UTF16.self)
    }

    /// The character a Wingdings or Symbol bullet at this code stands for; the ones Office uses, else a plain bullet.
    static func symbolBullet(_ code: Int) -> UInt16 {
        switch code {
        case 0xA7: return 0x25AA
        case 0xD8: return 0x27A2
        case 0xFC: return 0x2713
        case 0x76: return 0x2756
        default: return 0x2022
        }
    }

    static func format(_ value: Int, _ format: String) -> String {
        switch format {
        case "lowerLetter": return letters(value, false)
        case "upperLetter": return letters(value, true)
        case "lowerRoman": return roman(value, false)
        case "upperRoman": return roman(value, true)
        case "decimalZero": return value >= 0 && value < 10 ? "0" + String(value) : String(value)
        case "none": return ""
        default: return String(value)
        }
    }

    // a to z, then aa, bb, cc: the letter repeats, as in Word.
    private static func letters(_ value: Int, _ upper: Bool) -> String {
        if value < 1 { return String(value) }
        let letter = Character(Unicode.Scalar(UInt8((upper ? 0x41 : 0x61) + (value - 1) % 26)))
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    private static func roman(_ value: Int, _ upper: Bool) -> String {
        if value < 1 || value > 3999 { return String(value) }
        let values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
        let symbols = ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
        var rest = value
        var o = ""
        for i in 0..<values.count {
            while rest >= values[i] {
                o += symbols[i]
                rest -= values[i]
            }
        }
        return upper ? o : String(decoding: o.utf8.map { $0 + 32 }, as: UTF8.self)
    }
}
