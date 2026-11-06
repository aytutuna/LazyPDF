import Foundation

// Twin of windows/LazyPDF.Core/Editing/TextEditor.cs: changes the text of a `PageModel` into an `EditBatch`; nothing is
// written until the batch is applied. The paragraph operations are in TextEditor.Paragraph.swift.

/// What to change about the look of some text; a nil member is left as it is. `family` is looked up through the editor's
/// `FontSource`. `bold` and `italic` with `family` pick a new font for the text. `size` is in text space units (what
/// `Tf` takes), `charSpacing` the extra space after each character in text space units (`Tc`).
public struct TextStyleChange: Equatable {
    public var family: String?
    public var bold: Bool?
    public var italic: Bool?
    public var size: Double?
    public var color: RgbColor?
    public var charSpacing: Double?

    public init(family: String? = nil, bold: Bool? = nil, italic: Bool? = nil, size: Double? = nil, color: RgbColor? = nil, charSpacing: Double? = nil) {
        self.family = family
        self.bold = bold
        self.italic = italic
        self.size = size
        self.color = color
        self.charSpacing = charSpacing
    }

    var needsFont: Bool { family != nil || bold != nil || italic != nil }
}

/// A content stream run, the key glyphs are grouped by.
struct UnitVisit: Hashable {
    let unit: ContentUnit
    let visit: FormVisit?
}

/// The glyphs grouped by the stream run they are shown in, in the order each run first occurs, as LINQ's GroupBy does.
func groupedByRun(_ glyphs: [EditGlyph]) -> [(key: UnitVisit, glyphs: [EditGlyph])] {
    var groups: [(key: UnitVisit, glyphs: [EditGlyph])] = []
    var index: [UnitVisit: Int] = [:]
    for g in glyphs {
        let key = UnitVisit(unit: g.unit, visit: g.visit)
        if let at = index[key] {
            groups[at].glyphs.append(g)
        } else {
            index[key] = groups.count
            groups.append((key, [g]))
        }
    }
    return groups
}

/// The glyphs in the order the stream shows them: by operation, then string, then byte; equal ones keep their order.
func inStreamOrder(_ glyphs: [EditGlyph]) -> [EditGlyph] {
    glyphs.enumerated().sorted { a, b in
        if a.element.op != b.element.op { return a.element.op < b.element.op }
        if a.element.element != b.element.element { return a.element.element < b.element.element }
        if a.element.offset != b.element.offset { return a.element.offset < b.element.offset }
        return a.offset < b.offset
    }.map { $0.element }
}

final class TextEditor {
    let model: PageModel
    let batch: EditBatch
    let builder: TextBuilder
    let fonts: FontSource?

    init(_ model: PageModel, _ batch: EditBatch, _ builder: TextBuilder, _ fonts: FontSource?) {
        self.model = model
        self.batch = batch
        self.builder = builder
        self.fonts = fonts
    }

    var grew = false
    var overlaps = false

    static func placeOf(_ g: EditGlyph) -> Place { Place(g.unit, g.visit) }

    func patchOf(_ g: EditGlyph) throws -> ShowPatch {
        guard let patch = batch.patch(Self.placeOf(g), g.op) else { throw EditConflictException(EditingText.sharedForm) }
        return patch
    }

    func check(_ glyphs: [EditGlyph]) throws {
        for g in glyphs {
            if g.font.isVertical { throw EditConflictException(EditingText.vertical) }
            if g.hasActualText { throw EditConflictException(EditingText.actualText) }
        }
    }

    // Text after a cut keeps its place, by a move forward of the width cut, except in the run the new text goes into
    // (the run of flow), where it follows the new text. A twin that got no new text is not in the flow: what follows it
    // moves by what the visible text moved, `growth` along the line, so that the two stay together.
    func cutAll(_ glyphs: [EditGlyph], _ flow: EditGlyph?, _ unplaced: [EditGlyph]? = nil, _ growth: Double = 0) throws {
        let all = glyphs.flatMap { [$0] + $0.twins }
        for g in all { try patchOf(g).cut(g.element, g.offset, g.offset + g.length) }
        var flows: [EditGlyph] = []
        if let flow { flows = ([flow] + flow.twins).filter { f in !(unplaced ?? []).contains { $0 === f } } }
        for group in Self.runs(all.filter { g in !flows.contains { Self.sameRun($0, g) } }) {
            let first = group[0]
            let counted = unplaced != nil && group.contains { g in unplaced?.contains { $0 === g } ?? false }
            let moved = group.reduce(0) { $0 + $1.advance } + (counted ? growth / first.unitX : 0)
            let amount = -moved * 1000 / (first.fontSize * first.scale)
            if amount.isFinite && abs(amount) > 1e-6 { try patchOf(first).insert(first.element, first.offset, [ShowShift(amount)]) }
        }
    }

    func anchorOf(_ glyphs: [EditGlyph]) -> EditGlyph {
        glyphs.first { $0.text.utf16.contains { !$0.isWhiteSpace } } ?? glyphs[0]
    }

    /// Replaces the glyphs of a range of characters with `text` in their font, at the place of the first of them.
    func replace(_ range: TextRange, _ text: String, _ style: TextStyleChange? = nil) throws {
        let glyphs = model.glyphsIn(range)
        if glyphs.isEmpty { throw EditConflictException(EditingText.noText) }
        try check(glyphs)
        if style == nil {
            let groups = Self.styleGroups(glyphs)
            if groups.count > 1 {
                try replaceByStyle(range, glyphs, groups, text)
                return
            }
        }
        let anchor = anchorOf(glyphs)
        let (pieces, wrap) = try piecesFor(Self.placeOf(glyphs[0]), glyphs[0], anchor, text, style)
        let newWidth = pieces.reduce(0) { $0 + $1.advance } * anchor.unitX
        let shift = alignmentShift(range, glyphs, newWidth)
        try putText(glyphs[0], false, pieces, wrap, shift)
        let unplaced = try putTwins(glyphs[0], anchor, pieces, text, style, wrap, shift)
        try cutAll(glyphs, glyphs[0], unplaced, shift + newWidth - Self.extent(glyphs))
        checkRoom(range, glyphs, newWidth)
    }

    // A word set partly in another size, font or colour (a drop cap, a changed letter) takes its new letters in the same parts.
    private func replaceByStyle(_ range: TextRange, _ glyphs: [EditGlyph], _ groups: [[EditGlyph]], _ text: String) throws {
        let runes = text.unicodeScalars.map { String($0) }
        var next = 0
        var width = 0.0
        for i in 0..<groups.count {
            let group = groups[i]
            let take = i == groups.count - 1 ? runes.count - next : Swift.min(group.count, runes.count - next)
            let part = runes[next..<next + take].joined()
            next += take
            if part.isEmpty {
                try cutAll(group, nil)
                continue
            }
            let anchor = anchorOf(group)
            let pieces = try builder.build(Self.placeOf(group[0]), anchor, part)
            try putText(group[0], false, pieces, StyleWrap(), 0)
            let unplaced = try putTwins(group[0], anchor, pieces, part, nil, StyleWrap(), 0)
            let groupWidth = pieces.reduce(0) { $0 + $1.advance } * anchor.unitX
            try cutAll(group, group[0], unplaced, groupWidth - Self.extent(group))
            width += groupWidth
        }
        checkRoom(range, glyphs, width)
    }

    private static func styleGroups(_ glyphs: [EditGlyph]) -> [[EditGlyph]] {
        var groups: [[EditGlyph]] = []
        for g in glyphs {
            if let last = groups.last?.last, last.font === g.font, last.color == g.color, abs(last.userSize - g.userSize) < 0.01 * last.userSize {
                groups[groups.count - 1].append(g)
            } else {
                groups.append([g])
            }
        }
        return groups
    }

    /// Adds text before the character `index`, or after the last one when it is past the end.
    func insert(_ index: Int, _ text: String) throws {
        let chars = model.text.chars
        if index < 0 { throw EditConflictException(EditingText.noText) }
        var glyph: EditGlyph?
        var after = false
        var i = Swift.min(index, chars.count - 1)
        while i >= 0 && glyph == nil {
            glyph = model.charGlyphs[i]
            if glyph != nil { after = i < index }
            i -= 1
        }
        i = index
        while i < chars.count && glyph == nil {
            glyph = model.charGlyphs[i]
            i += 1
        }
        guard let found = glyph else { throw EditConflictException(EditingText.noText) }
        try check([found])
        let (pieces, wrap) = try piecesFor(Self.placeOf(found), found, found, text, nil)
        try putText(found, after, pieces, wrap, 0)
    }

    // Removes the glyphs and moves what follows them in the same string back to where it was.
    func delete(_ range: TextRange) throws {
        let glyphs = model.glyphsIn(range)
        if glyphs.isEmpty { throw EditConflictException(EditingText.noText) }
        try check(glyphs)
        try cutAll(glyphs, nil)
    }

    // Glyphs that are neighbours in one string.
    static func runs(_ glyphs: [EditGlyph]) -> [[EditGlyph]] {
        var runs: [[EditGlyph]] = []
        for g in glyphs {
            if let last = runs.last?.last, last.unit === g.unit, last.op == g.op, last.element == g.element, last.offset + last.length == g.offset {
                runs[runs.count - 1].append(g)
            } else {
                runs.append([g])
            }
        }
        return runs
    }

    // A twin is shown in a font and a stream of its own, so the codes of the anchor's font mean nothing to it: its text is built again for it.
    func putTwins(_ glyph: EditGlyph, _ anchor: EditGlyph, _ pieces: [EditPiece], _ text: String, _ style: TextStyleChange?, _ wrap: StyleWrap, _ shift: Double) throws -> [EditGlyph] {
        var unplaced: [EditGlyph] = []
        for twin in glyph.twins {
            if twin.font === anchor.font && twin.unit === anchor.unit {
                try putText(twin, false, pieces, wrap, shift)
                continue
            }
            let mark = batch.save()
            do {
                let (own, twinWrap) = try piecesFor(Self.placeOf(twin), twin, twin, text, style)
                try putText(twin, false, own, twinWrap, shift)
            } catch is EditConflictException where twin.renderMode == 3 {
                // A hidden copy that cannot show the new letters is cut with the rest rather than blocking the edit.
                batch.restore(mark)
                unplaced.append(twin)
            }
        }
        return unplaced
    }

    func putText(_ at: EditGlyph, _ after: Bool, _ pieces: [EditPiece], _ wrap: StyleWrap, _ shift: Double) throws {
        let items = try TextBuilder.items(Self.placeOf(at), at, pieces, shift: Self.shiftAmount(at, shift), before: wrap.before, after: wrap.after, size: wrap.size)
        try patchOf(at).insert(at.element, at.offset + (after ? at.length : 0), items)
    }

    /// Thousandths of the font size for a shift along the line, in user space units.
    static func shiftAmount(_ g: EditGlyph, _ shift: Double) -> Double { shift == 0 ? 0 : shift / g.unitX * 1000 / (g.fontSize * g.scale) }

    /// The operators round new text that change its look, and the size it is set at.
    struct StyleWrap {
        var before: [UInt8]?
        var after: [UInt8]?
        var size: Double?
    }

    func piecesFor(_ place: Place, _ at: EditGlyph, _ anchor: EditGlyph, _ text: String, _ style: TextStyleChange?) throws -> (pieces: [EditPiece], wrap: StyleWrap) {
        guard let style else { return (try builder.build(place, anchor, text), StyleWrap()) }
        let state = place.states.at(at.op)
        let before = ContentWriter()
        let after = ContentWriter()
        var restore: StateParts = []
        var size: Double?
        let strokes = at.renderMode == 1 || at.renderMode == 2
        if let color = style.color {
            before.fillRgb(Double(color.r) / 255.0, Double(color.g) / 255.0, Double(color.b) / 255.0)
            if strokes { before.strokeRgb(Double(color.r) / 255.0, Double(color.g) / 255.0, Double(color.b) / 255.0) }
            restore.insert(.fill)
            if strokes { restore.insert(.stroke) }
        }
        if let tc = style.charSpacing {
            before.charSpacing(tc)
            restore.insert(.charSpacing)
        }
        var pieces: [EditPiece]
        if style.needsFont {
            if state.font == nil { throw EditConflictException(EditingText.fontSetOutside) }
            let fontSize = style.size ?? at.fontSize
            size = fontSize
            let draw = try standIn(anchor.font, style, text)
            guard let name = batch.addResource(place, "Font", draw.reference) else { throw EditConflictException(EditingText.sharedForm) }
            pieces = TextBuilder.buildWith(draw, name, anchor, text, fontSize)
        } else {
            pieces = try builder.build(place, anchor, text)
            if let newSize = style.size {
                guard let fontName = state.font?.operands.first as? PdfName else { throw EditConflictException(EditingText.fontSetOutside) }
                before.font(fontName.value, newSize)
                restore.insert(.font)
                let factor = newSize / at.fontSize
                pieces = pieces.map { EditPiece(text: $0.text, bytes: $0.bytes, advance: $0.advance * factor, font: $0.font, isSpace: $0.isSpace, shift: $0.shift) }
            }
        }
        if !restore.isEmpty { try place.states.at(at.op + 1).replay(after, restore) }
        return (pieces, StyleWrap(before: before.length > 0 ? before.toArray() : nil, after: after.length > 0 ? after.toArray() : nil, size: size))
    }

    // A font of the family and style the change asks for; bold and italic start from those of the font in the file.
    private func standIn(_ font: PdfFont, _ change: TextStyleChange, _ text: String) throws -> PdfDrawFont {
        guard let fonts else { throw EditConflictException(EditingText.noFont) }
        let (families, current) = FontMatch.for(font)
        var style: FontStyles = []
        if change.bold ?? current.contains(.bold) { style.insert(.bold) }
        if change.italic ?? current.contains(.italic) { style.insert(.italic) }
        let candidates = change.family.map { [$0] } ?? families
        let embedder = PdfFontEmbedder(model.document, fonts)
        for candidate in candidates {
            if let draw = try embedder.add(candidate, style, [text], embed: font.isEmbedded) {
                if !draw.missing.isEmpty { throw EditConflictException(EditingText.noGlyphs(lettersOf(draw.missing))) }
                return draw
            }
        }
        throw EditConflictException(EditingText.noFont)
    }

    /// Changes the look of the text of a range without changing its characters where the font stays the same.
    func restyle(_ range: TextRange, _ change: TextStyleChange) throws {
        let glyphs = model.glyphsIn(range)
        if glyphs.isEmpty { throw EditConflictException(EditingText.noText) }
        try check(glyphs)
        if change.needsFont {
            try replace(range, model.text.getText(range), change)
            return
        }
        var changed: StateParts = []
        if change.size != nil { changed.insert(.font) }
        if change.charSpacing != nil { changed.insert(.charSpacing) }
        if change.color != nil { changed.formUnion([.fill, .stroke, .mode]) }
        for run in streamRuns(glyphs.flatMap { [$0] + $0.twins }, changed) {
            guard let a = run.first, let b = run.last else { continue }
            if !Self.balanced(a.unit, a.op, b.op) { throw EditConflictException(EditingText.unbalanced) }
            let state = Self.placeOf(a).states.at(a.op)
            let before = ContentWriter()
            var restore: StateParts = []
            if let size = change.size {
                guard let name = state.font?.operands.first as? PdfName else { throw EditConflictException(EditingText.fontSetOutside) }
                before.font(name.value, size)
                restore.insert(.font)
            }
            if let c = change.color {
                before.fillRgb(Double(c.r) / 255.0, Double(c.g) / 255.0, Double(c.b) / 255.0)
                restore.insert(.fill)
                if a.renderMode == 1 || a.renderMode == 2 {
                    before.strokeRgb(Double(c.r) / 255.0, Double(c.g) / 255.0, Double(c.b) / 255.0)
                    restore.insert(.stroke)
                }
            }
            if let tc = change.charSpacing {
                before.charSpacing(tc)
                restore.insert(.charSpacing)
            }
            let after = ContentWriter()
            try Self.placeOf(b).states.at(b.op + 1).replay(after, restore)
            try patchOf(a).insert(a.element, a.offset, [ShowOps(before.toArray())])
            try patchOf(b).insert(b.element, b.offset + b.length, [ShowOps(after.toArray())])
        }
    }

    private static let painted: Set<String> = ["Do", "sh", "BI", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*"]

    // The glyphs in the order the stream shows them, cut into runs that nothing else is drawn inside of, that stay
    // within one q level, and that no operator setting one of `parts` falls inside of, so that operators put round a
    // run reach these glyphs only and are not undone by the stream.
    func streamRuns(_ glyphs: [EditGlyph], _ parts: StateParts) -> [[EditGlyph]] {
        var unique: [EditGlyph] = []
        var own = Set<EditGlyph>()
        for g in glyphs where own.insert(g).inserted { unique.append(g) }
        var runs: [[EditGlyph]] = []
        for group in groupedByRun(unique) {
            let ops = group.key.unit.operations
            var last: EditGlyph?
            for g in inStreamOrder(group.glyphs) {
                var apart = false
                if let previous = last, let current = runs.last?.first {
                    apart = model.foreignBetween(g.unit, previous, g, own) || !Self.balanced(g.unit, current.op, g.op)
                    var i = previous.op + 1
                    while !apart && i < g.op {
                        if Self.painted.contains(ops[i].operator) { apart = true }
                        i += 1
                    }
                    i = previous.op + 1
                    while !apart && i <= g.op {
                        if !Self.sets(ops[i].operator).intersection(parts).isEmpty { apart = true }
                        i += 1
                    }
                }
                if last == nil || apart { runs.append([g]) } else { runs[runs.count - 1].append(g) }
                last = g
            }
        }
        return runs
    }

    private static func sets(_ op: String) -> StateParts {
        switch op {
        case "Tf": return .font
        case "Tc": return .charSpacing
        case "Tw": return .wordSpacing
        case "\"": return [.charSpacing, .wordSpacing]
        case "Tz": return .scale
        case "TL": return .leading
        case "Tr": return .mode
        case "Ts": return .rise
        case "g", "rg", "k", "cs", "sc", "scn": return .fill
        case "G", "RG", "K", "CS", "SC", "SCN": return .stroke
        default: return []
        }
    }

    /// The operations from `first` to `last` open and close the same q levels, so that an operator put round them cannot leak.
    static func balanced(_ unit: ContentUnit, _ first: Int, _ last: Int) -> Bool {
        let states = unit.states
        let depth = states.at(first).depth
        var i = first
        while i <= last {
            if states.at(i).depth < depth { return false }
            i += 1
        }
        return states.at(last + 1).depth == depth
    }

    private func alignmentShift(_ range: TextRange, _ glyphs: [EditGlyph], _ newWidth: Double) -> Double {
        let first = firstChar(range)
        if first < 0 { return 0 }
        let line = model.text.lines[model.text.chars[first].line]
        let lineGlyphs = model.glyphsIn(line.range)
        guard lineGlyphs.count == glyphs.count, let alignment = model.alignmentOfLine(line.index), alignment != .left, alignment != .justify else { return 0 }
        let oldWidth = Self.extent(glyphs)
        return alignment == .right ? oldWidth - newWidth : (oldWidth - newWidth) / 2
    }

    private func firstChar(_ range: TextRange) -> Int {
        var i = Swift.max(range.start, 0)
        let end = Swift.min(range.end, model.charGlyphs.count)
        while i < end {
            if model.charGlyphs[i] != nil { return i }
            i += 1
        }
        return -1
    }

    /// Length along the first glyph's baseline from its origin to the end of the last glyph.
    static func extent(_ glyphs: [EditGlyph]) -> Double {
        let (ux, uy) = glyphs[0].direction
        let last = glyphs[glyphs.count - 1]
        return (last.origin.x - glyphs[0].origin.x) * ux + (last.origin.y - glyphs[0].origin.y) * uy + last.advance * last.unitX
    }

    // Later text on the line that is not part of the run does not move, so new text that grows can run into it.
    private func checkRoom(_ range: TextRange, _ glyphs: [EditGlyph], _ newWidth: Double) {
        let oldWidth = Self.extent(glyphs)
        if newWidth <= oldWidth + 0.01 { return }
        let first = glyphs[0]
        let last = glyphs[glyphs.count - 1]
        let (ux, uy) = first.direction
        let start = first.origin.x * ux + first.origin.y * uy
        let end = start + newWidth
        var i = Swift.max(range.end, 0)
        let limit = range.end > model.charGlyphs.count ? model.charGlyphs.count : Swift.min(model.charGlyphs.count, range.end + 400)
        while i < limit {
            defer { i += 1 }
            guard let next = model.charGlyphs[i], !next.text.utf16.allSatisfy({ $0.isWhiteSpace }) else { continue }
            let across = abs((next.origin.x - first.origin.x) * -uy + (next.origin.y - first.origin.y) * ux)
            let nextStart = next.origin.x * ux + next.origin.y * uy
            if across > 0.3 * first.userSize || nextStart < start { continue }
            if Self.sameRun(last, next) { return }
            if end > nextStart - 0.05 * first.userSize { overlaps = true }
            return
        }
        let box = model.page.cropBox
        let (ex, ey) = (first.origin.x + ux * newWidth, first.origin.y + uy * newWidth)
        if ex > box.right || ex < box.left || ey > box.top || ey < box.bottom { overlaps = true }
    }

    // Both are shown one after the other with no new position set between them.
    static func sameRun(_ a: EditGlyph, _ b: EditGlyph) -> Bool {
        if a.unit !== b.unit || b.op < a.op { return false }
        let ops = a.unit.operations
        var i = a.op + 1
        while i <= b.op && i < ops.count {
            if positioning.contains(ops[i].operator) { return false }
            i += 1
        }
        return true
    }

    private static let positioning: Set<String> = ["Td", "TD", "Tm", "T*", "'", "\"", "BT", "ET"]
}
