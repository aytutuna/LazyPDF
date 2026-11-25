// Twin of windows/LazyPDF.Core/Content/LineShaper.cs: resolves the bidi levels of a line (UAX 9), cuts it into
// directional runs, shapes each run and puts the runs in display order. Lines are broken on logical text before
// this, so a line is one paragraph or the part of one. Positions are UTF-16 units, as in the C# engine.

/// A glyph of a line with the stretch [`start`, `end`) of the line's text it stands for. `mirrored`: the glyph is the
/// mirror image of the one the character has, as for a bracket in right-to-left text.
struct LineGlyph {
    let shaped: ShapedGlyph
    let start: Int
    let end: Int
    let mirrored: Bool
}

/// One line of text ready to draw: `glyphs` in display order, left to right. `units` is the logical text without
/// control characters; `width` is in 1/1000 em. `needsActualText`: the glyphs do not map one to one to the
/// characters (ligatures, mirrored brackets), so copying them would not give the text; the writer wraps the line
/// in marked content with /ActualText.
struct ShapedLine {
    let units: [UInt16]
    let glyphs: [LineGlyph]
    let width: Double
    let needsActualText: Bool
    let rightToLeft: Bool

    /// The text a reader gets back: the text without direction marks and joiners.
    var actualText: String {
        var kept: [UInt16] = []
        for rune in Utf16Rune.all(units) where !CmapShaper.isInvisible(rune.value) {
            kept.append(contentsOf: units[rune.at..<(rune.at + rune.length)])
        }
        return String(decoding: kept, as: UTF16.self)
    }
}

final class LineShaper {
    private static let cacheLimit = 2048

    private struct Key: Hashable {
        let units: [UInt16]
        let level: Int
    }

    private let file: FontFile
    private let shaper: Shaper
    private let measure: TrueTypeFont
    private let language: String?
    private var cache: [Key: ShapedLine] = [:]

    init(_ file: FontFile, _ shaper: Shaper, _ measure: TrueTypeFont, _ language: String?) {
        self.file = file
        self.shaper = shaper
        self.measure = measure
        self.language = language
    }

    /// `baseLevel` is 0, 1 or `BidiParagraph.auto` for the first strong character.
    func shape(_ text: String, _ baseLevel: Int = BidiParagraph.auto) -> ShapedLine {
        let key = Key(units: Array(text.utf16), level: baseLevel)
        if let known = cache[key] { return known }
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        let built = build(key.units, baseLevel)
        cache[key] = built
        return built
    }

    /// One run of a single direction, as a layout that has resolved the levels itself cuts it. Brackets are mirrored
    /// when it runs right to left.
    func shapeRun(_ text: String, rightToLeft: Bool) -> ShapedLine {
        let key = Key(units: Array(text.utf16), level: rightToLeft ? 2 : 3)
        if let known = cache[key] { return known }
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        let clean = Self.clean(key.units)
        var glyphs: [LineGlyph] = []
        let mirrored = !clean.isEmpty && addRun(&glyphs, clean, 0, clean.count, rightToLeft ? 1 : 0)
        let built = Self.finish(clean, glyphs, mirrored, rightToLeft)
        cache[key] = built
        return built
    }

    private static func clean(_ units: [UInt16]) -> [UInt16] {
        units.filter { $0 >= 0x20 && $0 != 0x85 && $0 != 0x2028 && $0 != 0x2029 }
    }

    private func build(_ units: [UInt16], _ baseLevel: Int) -> ShapedLine {
        let clean = Self.clean(units)
        var glyphs: [LineGlyph] = []
        var mirrored = false
        var rtl = baseLevel == 1
        let text = String(decoding: clean, as: UTF16.self)
        if !clean.isEmpty && (baseLevel == 1 || Scripts.needsBidi(text)) {
            let paragraph = BidiParagraph(text, baseLevel: baseLevel)
            rtl = paragraph.level == 1
            var runs = Self.runs(paragraph.lineLevels(0, clean.count))
            Self.reorder(&runs)
            for run in runs where addRun(&glyphs, clean, run.start, run.end, run.level) { mirrored = true }
        } else if !clean.isEmpty {
            _ = addRun(&glyphs, clean, 0, clean.count, 0)
        }
        return Self.finish(clean, glyphs, mirrored, rtl)
    }

    private static func finish(_ clean: [UInt16], _ glyphs: [LineGlyph], _ mirrored: Bool, _ rtl: Bool) -> ShapedLine {
        let expected = Utf16Rune.all(clean).filter { !CmapShaper.isInvisible($0.value) }.count
        let actual = mirrored || glyphs.count != expected || glyphs.contains { !isOneRune(clean, $0) }
        return ShapedLine(units: clean, glyphs: glyphs, width: glyphs.reduce(0.0) { $0 + $1.shaped.advance }, needsActualText: actual, rightToLeft: rtl)
    }

    private static func isOneRune(_ units: [UInt16], _ g: LineGlyph) -> Bool {
        guard let rune = Utf16Rune.at(units, g.start) else { return false }
        return g.end - g.start == rune.length
    }

    private func addRun(_ glyphs: inout [LineGlyph], _ line: [UInt16], _ start: Int, _ end: Int, _ level: Int) -> Bool {
        let rtl = level & 1 == 1
        let original = Array(line[start..<end])
        var run = original
        var mirrored = false
        if rtl { run = Self.mirror(run, &mirrored) }
        let shaped = shaper.shape(String(decoding: run, as: UTF16.self), file, rightToLeft: rtl, language: language)
            ?? CmapShaper.shape(measure, run, rtl)

        // A glyph stands for the text from its cluster to the next cluster start, whichever way the run is drawn.
        let starts = Set(shaped.map { min(max($0.cluster, 0), run.count) }).sorted()
        var nextOf: [Int: Int] = [:]
        for (i, s) in starts.enumerated() { nextOf[s] = i + 1 < starts.count ? starts[i + 1] : run.count }
        for g in shaped {
            let from = min(max(g.cluster, 0), run.count)
            glyphs.append(LineGlyph(shaped: g, start: start + from, end: start + (nextOf[from] ?? run.count),
                                    mirrored: mirrored && from < run.count && run[from] != original[from]))
        }
        return mirrored
    }

    private static func mirror(_ run: [UInt16], _ changed: inout Bool) -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(run.count)
        for rune in Utf16Rune.all(run) {
            let mirror = BidiData.mirror(rune.value)
            if mirror != rune.value { changed = true }
            result.append(contentsOf: String(Unicode.Scalar(UInt32(mirror)) ?? "\u{FFFD}").utf16)
        }
        return result
    }

    // Runs of equal level; a character the algorithm removed (level -1) ends a run and is not drawn.
    private static func runs(_ levels: [Int]) -> [(start: Int, end: Int, level: Int)] {
        var runs: [(start: Int, end: Int, level: Int)] = []
        var start = 0
        var i = 1
        while i <= levels.count {
            if i < levels.count && levels[i] == levels[start] {
                i += 1
                continue
            }
            if levels[start] >= 0 { runs.append((start, i, levels[start])) }
            start = i
            i += 1
        }
        return runs
    }

    // L2 on whole runs: from the highest level down to the lowest odd one, turn every stretch at that level or above.
    private static func reorder(_ runs: inout [(start: Int, end: Int, level: Int)]) {
        if runs.isEmpty { return }
        let highest = runs.map { $0.level }.max() ?? 0
        let lowestOdd = runs.filter { $0.level & 1 == 1 }.map { $0.level }.min() ?? Int.max
        var level = highest
        while level >= lowestOdd {
            var i = 0
            while i < runs.count {
                if runs[i].level < level {
                    i += 1
                    continue
                }
                var j = i
                while j + 1 < runs.count && runs[j + 1].level >= level { j += 1 }
                runs[i...j].reverse()
                i = j + 1
            }
            level -= 1
        }
    }
}
