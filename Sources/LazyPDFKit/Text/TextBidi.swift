import Foundation

// Twin of windows/LazyPDF.Core/Text/TextBidi.cs: turns a line of glyphs in visual order into logical order (UAX #9
// rules L1 to L2 run backwards, with a simplified resolution of weak and neutral characters). Glyphs are already
// placed where they show, so the content stream order says nothing about the logical order.

enum BidiClass {
    case l

    /// Hebrew and Arabic letters.
    case r
    case en
    case an
    case n
}

enum TextBidi {
    static func classOf(_ text: String) -> BidiClass {
        var weak = BidiClass.n
        for c in text.utf16 {
            let cls = classOf(c)
            if cls == .l || cls == .r { return cls }
            if cls == .en || cls == .an { weak = cls }
        }
        return weak
    }

    private static func classOf(_ c: UInt16) -> BidiClass {
        if c < 0x590 { return c >= 0x30 && c <= 0x39 ? .en : c.isLetter ? .l : .n }
        if (c >= 0x0660 && c <= 0x0669) || c == 0x066B || c == 0x066C { return .an }
        if c >= 0x06F0 && c <= 0x06F9 { return .en }
        if (c >= 0x0590 && c <= 0x08FF) || (c >= 0xFB1D && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFF) {
            return c.isLetter ? .r : .n
        }
        if c >= 0x2000 && c <= 0x206F { return .n }
        return c.isLetter ? .l : .n
    }

    /// Reorders in place and sets `FlowGlyph.level`; true when the line reads right to left.
    static func toLogical(_ line: inout [FlowGlyph], _ pageRtl: Bool) -> Bool {
        let n = line.count
        var strongR = 0, strongL = 0
        var classes = [BidiClass](repeating: .n, count: n)
        for i in 0..<n {
            classes[i] = classOf(line[i].text)
            if classes[i] == .r {
                strongR += 1
            } else if classes[i] == .l {
                strongL += 1
            }
        }
        for g in line { g.level = 0 }
        if strongR == 0 { return false }

        let rtl = pageRtl ? strongR > 0 : strongR > strongL
        let para = rtl ? 1 : 0, evenL = rtl ? 2 : 0
        var levels = [Int](repeating: 0, count: n)
        // Nearest letter on either side, 1 for right to left; the paragraph direction when there is none.
        var before = [Int](repeating: 0, count: n)
        var after = [Int](repeating: 0, count: n)
        var last = para
        for i in 0..<n {
            if classes[i] == .l || classes[i] == .r { last = classes[i] == .r ? 1 : 0 }
            before[i] = last
        }
        var next = para
        for i in stride(from: n - 1, through: 0, by: -1) {
            if classes[i] == .l || classes[i] == .r { next = classes[i] == .r ? 1 : 0 }
            after[i] = next
        }
        for i in 0..<n {
            switch classes[i] {
            case .l: levels[i] = evenL
            case .r: levels[i] = 1
            case .an: levels[i] = 2
            case .en: levels[i] = rtl || (before[i] == 1 && after[i] == 1) ? 2 : 0
            case .n: levels[i] = -1
            }
        }
        // Everything to the right of a neutral is still unresolved when it is reached, so where the scans to the right stop is
        // known beforehand; rescanning for every neutral is quadratic on a long run of them.
        let terminator = (0..<n).map { levels[$0] < 0 && isTerminator(line[$0].text) }
        var nextResolved = [Int](repeating: n, count: n)
        var endOfTerminators = [Int](repeating: n, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            nextResolved[i] = i + 1 < n && levels[i + 1] < 0 ? nextResolved[i + 1] : i + 1
            endOfTerminators[i] = i + 1 < n && terminator[i + 1] ? endOfTerminators[i + 1] : i + 1
        }
        for i in 0..<n {
            if levels[i] >= 0 { continue }
            if i > 0 && i + 1 < n && isNumber(classes[i - 1]) && isNumber(classes[i + 1]) && isJoiner(line[i].text) {
                levels[i] = levels[i - 1]
                continue
            }
            if isTerminator(line[i].text) {
                // W5: a run of terminators beside a European number belongs to the number.
                var left1 = i - 1
                let right1 = endOfTerminators[i]
                while left1 >= 0 && levels[left1] < 0 && isTerminator(line[left1].text) { left1 -= 1 }
                if left1 >= 0 && classes[left1] == .en {
                    levels[i] = levels[left1]
                } else if right1 < n && classes[right1] == .en {
                    levels[i] = levels[right1]
                }
                if levels[i] >= 0 { continue }
            }
            var a = i - 1
            let b = nextResolved[i]
            while a >= 0 && levels[a] < 0 { a -= 1 }
            let left = a >= 0 ? direction(classes[a], levels[a]) : para, right = b < n ? direction(classes[b], levels[b]) : para
            let dir = left == right ? left : para
            levels[i] = dir == 1 ? 1 : evenL
        }
        for i in 0..<n { line[i].level = levels[i] }

        let highest = levels.max() ?? 0
        var lowestOdd = levels.filter { ($0 & 1) == 1 }.min() ?? Int.max
        if lowestOdd == Int.max { lowestOdd = highest + 1 }
        var level = lowestOdd
        while level <= highest {
            var i = 0
            while i < n {
                if line[i].level < level {
                    i += 1
                    continue
                }
                var j = i
                while j < n && line[j].level >= level { j += 1 }
                line[i..<j].reverse()
                i = j
            }
            level += 1
        }
        for g in line where (g.level & 1) == 1 { g.text = mirror(g.text) }
        return rtl
    }

    private static func isJoiner(_ text: String) -> Bool {
        text == "." || text == "," || text == ":" || text == "/" || text == "+" || text == "-"
    }

    private static func isTerminator(_ text: String) -> Bool {
        guard text.utf16.count == 1, let unit = text.utf16.first else { return false }
        switch unit {
        case 0x25, 0x24, 0x23, 0xA2, 0xA3, 0xA5, 0xB0, 0xB1, 0x20AC: return true
        default: return false
        }
    }

    private static func isNumber(_ cls: BidiClass) -> Bool { cls == .en || cls == .an }

    private static func direction(_ cls: BidiClass, _ level: Int) -> Int { cls == .l || (cls == .en && level == 0) ? 0 : 1 }

    private static func mirror(_ text: String) -> String {
        switch text {
        case "(": return ")"
        case ")": return "("
        case "[": return "]"
        case "]": return "["
        case "{": return "}"
        case "}": return "{"
        case "<": return ">"
        case ">": return "<"
        case "\u{AB}": return "\u{BB}"
        case "\u{BB}": return "\u{AB}"
        default: return text
        }
    }
}
