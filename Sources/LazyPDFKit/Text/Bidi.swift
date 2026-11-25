// Twin of windows/LazyPDF.Core/Text/Bidi.cs: the Unicode Bidirectional Algorithm (UAX #9) for one paragraph of
// logical text, from the paragraph level (P2, P3, or given) through the explicit levels (X1 to X10), weak types
// (W1 to W7), paired brackets (N0), neutrals (N1, N2) and implicit levels (I1, I2). Lines are cut afterwards:
// lineLevels applies L1 and visualOrder L2. A paragraph separator may only be the last character. Units are
// UTF-16 units, as in the C# engine.

final class BidiParagraph {
    static let auto = -1
    private static let maxDepth = 125
    private static let maxBracketDepth = 63

    private var cps: [Int] = []
    private var unitOf: [Int] = []
    private var cpOfUnit: [Int] = []
    private var orig: [BidiType] = []
    private var matchingPdi: [Int] = []
    private var matchingInitiator: [Int] = []
    private var embedding: [Int] = []
    private var resolved: [Int] = []

    /// The paragraph embedding level, 0 or 1.
    private(set) var level = 0

    /// The resolved level of each UTF-16 unit before line breaking; -1 for characters X9 removes.
    private(set) var levels: [Int] = []

    /// `baseLevel` is 0, 1, or `auto` for the first strong character (P2, P3).
    init(_ text: String, baseLevel: Int = BidiParagraph.auto) {
        let units = Array(text.utf16)
        var starts: [Int] = []
        cpOfUnit = [Int](repeating: 0, count: units.count + 1)
        var i = 0
        while i < units.count {
            cpOfUnit[i] = cps.count
            starts.append(i)
            let u = Int(units[i])
            if u >= 0xD800 && u < 0xDC00 && i + 1 < units.count && units[i + 1] >= 0xDC00 && units[i + 1] < 0xE000 {
                cps.append(0x10000 + ((u - 0xD800) << 10) + (Int(units[i + 1]) - 0xDC00))
                i += 1
                cpOfUnit[i] = cps.count - 1
            } else {
                cps.append(u)
            }
            i += 1
        }
        cpOfUnit[units.count] = cps.count
        starts.append(units.count)
        unitOf = starts
        let n = cps.count

        orig = cps.map { BidiData.typeOf($0) }
        matchingPdi = [Int](repeating: -1, count: n)
        matchingInitiator = [Int](repeating: -1, count: n)
        matchIsolates()

        level = baseLevel == BidiParagraph.auto ? firstStrong(0, n) : baseLevel & 1
        embedding = [Int](repeating: 0, count: n)
        let types = explicit()
        resolved = [Int](repeating: 0, count: n)
        implicit(types)

        levels = (0..<units.count).map { resolved[cpOfUnit[$0]] }
    }

    /// The levels of units `start` to `end` of one line, after L1.
    func lineLevels(_ start: Int, _ end: Int) -> [Int] {
        let c0 = cpOfUnit[start]
        let line = lineLevelsByCode(c0, cpOfUnit[end])
        return (start..<end).map { line[cpOfUnit[$0] - c0] }
    }

    /// Unit indices of one line in display order, left to right (L2). Removed characters are left out.
    func visualOrder(_ start: Int, _ end: Int) -> [Int] {
        let c0 = cpOfUnit[start]
        let c1 = cpOfUnit[end]
        let line = lineLevelsByCode(c0, c1)
        var order: [Int] = []
        order.reserveCapacity(c1 - c0)
        var highest = 0
        var lowestOdd = Int.max
        for i in c0..<c1 {
            let l = line[i - c0]
            if l < 0 { continue }
            order.append(i)
            highest = max(highest, l)
            if l & 1 == 1 { lowestOdd = min(lowestOdd, l) }
        }
        var l = highest
        while l >= lowestOdd {
            var i = 0
            while i < order.count {
                if line[order[i] - c0] < l {
                    i += 1
                    continue
                }
                var j = i
                while j + 1 < order.count && line[order[j + 1] - c0] >= l { j += 1 }
                order[i...j].reverse()
                i = j + 1
            }
            l -= 1
        }
        var units: [Int] = []
        units.reserveCapacity(end - start)
        for c in order {
            units.append(contentsOf: unitOf[c]..<unitOf[c + 1])
        }
        return units
    }

    private func lineLevelsByCode(_ c0: Int, _ c1: Int) -> [Int] {
        var line = [Int](repeating: 0, count: c1 - c0)
        var trailing = true
        var i = c1 - 1
        while i >= c0 {
            var lv = resolved[i]
            if lv >= 0 {
                let t = orig[i]
                if t == .b || t == .s {
                    lv = level
                    trailing = true
                } else if trailing && (t == .ws || t == .fsi || t == .lri || t == .rli || t == .pdi) {
                    lv = level
                } else {
                    trailing = false
                }
            }
            line[i - c0] = lv
            i -= 1
        }
        return line
    }

    private static func isInitiator(_ t: BidiType) -> Bool { t == .lri || t == .rli || t == .fsi }

    // BD9
    private func matchIsolates() {
        var open: [Int] = []
        for i in 0..<orig.count {
            if BidiParagraph.isInitiator(orig[i]) {
                open.append(i)
            } else if orig[i] == .pdi, let o = open.popLast() {
                matchingPdi[o] = i
                matchingInitiator[i] = o
            }
        }
    }

    // P2 and P3 over [from, to): 1 for a right to left first strong character, else 0.
    private func firstStrong(_ from: Int, _ to: Int) -> Int {
        var i = from
        while i < to {
            let t = orig[i]
            if t == .l { return 0 }
            if t == .r || t == .al { return 1 }
            if BidiParagraph.isInitiator(t) { i = matchingPdi[i] < 0 ? to : matchingPdi[i] }
            i += 1
        }
        return 0
    }

    // X1 to X8: embedding levels, and the types with directional overrides applied.
    private func explicit() -> [BidiType] {
        let n = orig.count
        var types = orig
        let depth = BidiParagraph.maxDepth
        var levels = [Int](repeating: 0, count: depth + 2)
        var overrides = [BidiType](repeating: .on, count: depth + 2)
        var isolate = [Bool](repeating: false, count: depth + 2)
        var sp = 0
        levels[0] = level
        var overflowIsolates = 0
        var overflowEmbeddings = 0
        var validIsolates = 0
        for i in 0..<n {
            let t = orig[i]
            switch t {
            case .rle, .lre, .rlo, .lro:
                embedding[i] = -1
                let next = BidiParagraph.nextLevel(levels[sp], t == .rle || t == .rlo)
                if next <= depth && overflowIsolates == 0 && overflowEmbeddings == 0 {
                    sp += 1
                    levels[sp] = next
                    overrides[sp] = t == .rlo ? .r : t == .lro ? .l : .on
                    isolate[sp] = false
                } else if overflowIsolates == 0 {
                    overflowEmbeddings += 1
                }
            case .rli, .lri, .fsi:
                embedding[i] = levels[sp]
                if overrides[sp] != .on { types[i] = overrides[sp] }
                let rtl = t == .rli || (t == .fsi && firstStrong(i + 1, matchingPdi[i] < 0 ? n : matchingPdi[i]) == 1)
                let next = BidiParagraph.nextLevel(levels[sp], rtl)
                if next <= depth && overflowIsolates == 0 && overflowEmbeddings == 0 {
                    validIsolates += 1
                    sp += 1
                    levels[sp] = next
                    overrides[sp] = .on
                    isolate[sp] = true
                } else {
                    overflowIsolates += 1
                }
            case .pdi:
                if overflowIsolates > 0 {
                    overflowIsolates -= 1
                } else if validIsolates > 0 {
                    overflowEmbeddings = 0
                    while !isolate[sp] { sp -= 1 }
                    sp -= 1
                    validIsolates -= 1
                }
                embedding[i] = levels[sp]
                if overrides[sp] != .on { types[i] = overrides[sp] }
            case .pdf:
                embedding[i] = -1
                if overflowIsolates > 0 { break }
                if overflowEmbeddings > 0 {
                    overflowEmbeddings -= 1
                } else if !isolate[sp] && sp > 0 {
                    sp -= 1
                }
            case .b:
                embedding[i] = level
            case .bn:
                embedding[i] = -1
            default:
                embedding[i] = levels[sp]
                if overrides[sp] != .on { types[i] = overrides[sp] }
            }
        }
        return types
    }

    private static func nextLevel(_ current: Int, _ rtl: Bool) -> Int {
        rtl ? (current + 1) | 1 : (current + 2) & ~1
    }

    // X9 and X10: drop the removed characters, group the rest into level runs and chain those into
    // isolating run sequences.
    private func implicit(_ types: [BidiType]) {
        let n = cps.count
        var kept: [Int] = []
        kept.reserveCapacity(n)
        var position = [Int](repeating: -1, count: n)
        for i in 0..<n {
            resolved[i] = -1
            if embedding[i] < 0 { continue }
            position[i] = kept.count
            kept.append(i)
        }

        var runStart: [Int] = []
        var runOfPosition = [Int](repeating: 0, count: kept.count)
        for p in 0..<kept.count {
            if p == 0 || embedding[kept[p]] != embedding[kept[p - 1]] { runStart.append(p) }
            runOfPosition[p] = runStart.count - 1
        }
        runStart.append(kept.count)

        var sequence: [Int] = []
        for r in 0..<max(runStart.count - 1, 0) {
            let first = kept[runStart[r]]
            if orig[first] == .pdi && matchingInitiator[first] >= 0 { continue }
            sequence.removeAll(keepingCapacity: true)
            var run = r
            while true {
                for p in runStart[run]..<runStart[run + 1] { sequence.append(kept[p]) }
                let last = sequence[sequence.count - 1]
                if !BidiParagraph.isInitiator(orig[last]) || matchingPdi[last] < 0 { break }
                run = runOfPosition[position[matchingPdi[last]]]
            }
            resolveSequence(sequence, types, kept, position)
        }
    }

    private func resolveSequence(_ sequence: [Int], _ types: [BidiType], _ kept: [Int], _ position: [Int]) {
        let len = sequence.count
        let seqLevel = embedding[sequence[0]]
        let before = position[sequence[0]] > 0 ? embedding[kept[position[sequence[0]] - 1]] : level
        let lastIndex = sequence[len - 1]
        let after = BidiParagraph.isInitiator(orig[lastIndex]) || position[lastIndex] + 1 >= kept.count
            ? level : embedding[kept[position[lastIndex] + 1]]
        let sos: BidiType = (max(seqLevel, before) & 1) == 1 ? .r : .l
        let eos: BidiType = (max(seqLevel, after) & 1) == 1 ? .r : .l

        var w = sequence.map { types[$0] }

        // W1
        for k in 0..<len where w[k] == .nsm {
            let prev = k == 0 ? sos : w[k - 1]
            w[k] = BidiParagraph.isInitiator(prev) || prev == .pdi ? .on : prev
        }
        // W2, W3
        var strong = sos
        for k in 0..<len {
            if w[k] == .l || w[k] == .r || w[k] == .al {
                strong = w[k]
            } else if w[k] == .en && strong == .al {
                w[k] = .an
            }
        }
        for k in 0..<len where w[k] == .al { w[k] = .r }
        // W4
        if len > 2 {
            for k in 1..<(len - 1) {
                if w[k] == .es && w[k - 1] == .en && w[k + 1] == .en {
                    w[k] = .en
                } else if w[k] == .cs && w[k - 1] == w[k + 1] && (w[k - 1] == .en || w[k - 1] == .an) {
                    w[k] = w[k - 1]
                }
            }
        }
        // W5
        var pos = 0
        while pos < len {
            if w[pos] != .et {
                pos += 1
                continue
            }
            var end = pos
            while end < len && w[end] == .et { end += 1 }
            if (pos > 0 && w[pos - 1] == .en) || (end < len && w[end] == .en) {
                for j in pos..<end { w[j] = .en }
            }
            pos = end
        }
        // W6
        for k in 0..<len where w[k] == .es || w[k] == .et || w[k] == .cs { w[k] = .on }
        // W7
        strong = sos
        for k in 0..<len {
            if w[k] == .l || w[k] == .r {
                strong = w[k]
            } else if w[k] == .en && strong == .l {
                w[k] = .l
            }
        }

        let dir: BidiType = (seqLevel & 1) == 1 ? .r : .l
        resolveBrackets(sequence, &w, sos, dir)

        // N1, N2
        pos = 0
        while pos < len {
            if !BidiParagraph.isNeutral(w[pos]) {
                pos += 1
                continue
            }
            var end = pos
            while end < len && BidiParagraph.isNeutral(w[end]) { end += 1 }
            let lead = pos == 0 ? sos : BidiParagraph.direction(w[pos - 1])
            let trail = end == len ? eos : BidiParagraph.direction(w[end])
            let fill = lead == trail ? lead : dir
            for j in pos..<end { w[j] = fill }
            pos = end
        }

        // I1, I2
        for k in 0..<len {
            var l = seqLevel
            if (seqLevel & 1) == 0 {
                l += w[k] == .r ? 1 : (w[k] == .an || w[k] == .en ? 2 : 0)
            } else if w[k] == .l || w[k] == .an || w[k] == .en {
                l += 1
            }
            resolved[sequence[k]] = l
        }
    }

    private static func isNeutral(_ t: BidiType) -> Bool {
        t == .b || t == .s || t == .ws || t == .on || t == .fsi || t == .lri || t == .rli || t == .pdi
    }

    // L for L, R for R and for numbers.
    private static func direction(_ t: BidiType) -> BidiType { t == .l ? .l : .r }

    private static func strongOrNeutral(_ t: BidiType) -> BidiType {
        t == .l ? .l : (t == .r || t == .en || t == .an ? .r : .on)
    }

    // U+2329 and U+232A are canonically equivalent to U+3008 and U+3009 (BD16).
    private static func canonical(_ cp: Int) -> Int {
        cp == 0x2329 ? 0x3008 : cp == 0x232A ? 0x3009 : cp
    }

    // BD16 and N0.
    private func resolveBrackets(_ sequence: [Int], _ w: inout [BidiType], _ sos: BidiType, _ dir: BidiType) {
        let len = w.count
        var openers: [(closer: Int, index: Int)] = []
        var pairs: [(open: Int, close: Int)] = []
        for k in 0..<len where w[k] == .on {
            let cp = cps[sequence[k]]
            let (paired, opening) = BidiData.pairedBracket(cp)
            if paired == 0 { continue }
            if opening {
                if openers.count == BidiParagraph.maxBracketDepth { break }
                openers.append((BidiParagraph.canonical(paired), k))
                continue
            }
            let canonical = BidiParagraph.canonical(cp)
            var s = openers.count - 1
            while s >= 0 {
                if openers[s].closer == canonical {
                    pairs.append((openers[s].index, k))
                    openers.removeSubrange(s...)
                    break
                }
                s -= 1
            }
        }
        pairs.sort { $0.open < $1.open }

        let opposite: BidiType = dir == .l ? .r : .l
        for (open, close) in pairs {
            var foundDir = false
            var foundOpposite = false
            var k = open + 1
            while k < close {
                let s = BidiParagraph.strongOrNeutral(w[k])
                if s == dir {
                    foundDir = true
                    break
                }
                if s == opposite { foundOpposite = true }
                k += 1
            }
            let to: BidiType
            if foundDir {
                to = dir
            } else if foundOpposite {
                var context = sos
                var back = open - 1
                while back >= 0 {
                    let s = BidiParagraph.strongOrNeutral(w[back])
                    if s != .on {
                        context = s
                        break
                    }
                    back -= 1
                }
                to = context == opposite ? opposite : dir
            } else {
                continue
            }
            setBracket(sequence, &w, open, to)
            setBracket(sequence, &w, close, to)
        }
    }

    // Characters that were NSM before W1 and follow a bracket take its new direction.
    private func setBracket(_ sequence: [Int], _ w: inout [BidiType], _ k: Int, _ to: BidiType) {
        w[k] = to
        var j = k + 1
        while j < w.count && orig[sequence[j]] == .nsm {
            w[j] = to
            j += 1
        }
    }
}
