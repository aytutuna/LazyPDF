import Foundation

// Twin of windows/LazyPDF.Core/Editing/TextEditor.Paragraph.cs: paragraphs, laying new text out in the lines of a block,
// and moving the lines of a block.

extension TextEditor {
    struct Line {
        let glyphs: [EditGlyph]
        let start: Double
        let end: Double

        var first: EditGlyph { glyphs[0] }
        var last: EditGlyph { glyphs[glyphs.count - 1] }
    }

    func linesOf(_ block: TextObject) throws -> [Line] {
        var lines: [Line] = []
        let anchor = anchorOf(block.glyphs)
        let (ux, uy) = anchor.direction
        for line in block.lines {
            let glyphs = model.glyphsIn(line.range)
            if glyphs.isEmpty { continue }
            let first = glyphs[0]
            let start = first.origin.x * ux + first.origin.y * uy
            lines.append(Line(glyphs: glyphs, start: start, end: start + Self.extent(glyphs)))
        }
        if lines.isEmpty { throw EditConflictException(EditingText.noText) }
        try check(block.glyphs)
        if block.glyphs.contains(where: { $0.unit !== anchor.unit || $0.visit !== anchor.visit }) { throw EditConflictException(EditingText.moreStreams) }
        // A heading and the text under it are not one paragraph; laid out as one they would take the size of the first.
        if block.glyphs.contains(where: { !($0.text.utf16.first ?? 0x20).isWhiteSpace && abs($0.userSize - anchor.userSize) > 0.03 * anchor.userSize }) {
            throw EditConflictException(EditingText.mixedSizes)
        }
        return lines
    }

    // string.ReplaceLineEndings("\n").Split('\n'): CR LF, CR, LF, FF, NEL, LS and PS all end a paragraph.
    private static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 10 && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = v == 13
            if v == 10 || v == 13 || v == 12 || v == 0x85 || v == 0x2028 || v == 0x2029 {
                result.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }

    func paragraph(_ block: TextObject, _ text: String) throws {
        let lines = try linesOf(block)
        let anchor = anchorOf(lines[0].glyphs)
        let place = Self.placeOf(anchor)
        let left = lines.map { $0.start }.min() ?? 0, right = lines.map { $0.end }.max() ?? 0
        let multi = lines.count > 1
        let spacing = block.lineSpacing > 0 ? block.lineSpacing : anchor.userSize * 1.2
        let room = multi ? right - left : Double.infinity
        let anchorFont = place.states.at(anchor.op).font

        // Each line keeps its own character and word spacing and scaling, so a line is measured as the line it goes into.
        func lineAt(_ k: Int) -> EditGlyph { lines[Swift.min(k, lines.count - 1)].first }
        func widthOf(_ p: EditPiece, _ k: Int) -> Double {
            let g = lineAt(k)
            return (p.em * anchor.userSize + (g.charSpacing + (p.code32 ? g.wordSpacing : 0)) * g.unitX) * g.scale
        }

        var laid: [(pieces: [EditPiece], last: Bool)] = []
        for paragraph in Self.paragraphs(text) {
            let wrapped = Self.wrap(try builder.build(place, anchor, paragraph), room, laid.count, widthOf)
            for i in 0..<wrapped.count { laid.append((wrapped[i], i == wrapped.count - 1)) }
        }
        let alignment = multi ? block.alignment : .left
        func target(_ k: Int, _ width: Double) -> Double {
            switch alignment {
            case .center: return (left + right) / 2 - width / 2
            case .right: return right - width
            default: return k == 0 ? lines[0].start : lines.count > 1 ? lines[1].start : left
            }
        }

        var extra: [(pieces: [EditPiece], start: Double, last: Bool)] = []
        for k in 0..<laid.count {
            let (pieces, last) = laid[k]
            let width = pieces.reduce(0) { $0 + widthOf($1, k) }
            let start = target(k, width)
            if k >= lines.count {
                extra.append((pieces, start, last))
                continue
            }
            let line = lines[k]
            let at = line.first
            let word: Double? = alignment == .justify && !last ? Self.justifyWord(pieces, right - left - width, at) : nil
            let font = Self.fontFor(anchor, anchorFont, at)
            let (before, after) = try Self.normalize(font, at, word ?? 0)
            let items = try TextBuilder.items(Self.placeOf(at), at, pieces, shift: Self.shiftAmount(at, start - line.start), before: before, after: after,
                                          current: font ?? Self.placeOf(at).states.at(at.op).font)
            try patchOf(at).insert(at.element, at.offset, items)
            try cutAll(line.glyphs, at)
        }
        var k = laid.count
        while k < lines.count {
            try cutAll(lines[k].glyphs, nil)
            k += 1
        }
        if !extra.isEmpty {
            grew = true
            try addLines(place, lines, anchor, anchorFont, extra, spacing)
        }
    }

    // The anchor's font at the size that gives it the anchor's size on the line of `at`; nil when the line has them already.
    private static func fontFor(_ anchor: EditGlyph, _ anchorFont: ContentOperation?, _ at: EditGlyph) -> ContentOperation? {
        guard let anchorFont, let name = anchorFont.operands.first as? PdfName, at.userSize > 0 else { return nil }
        if at.font === anchor.font && abs(at.userSize - anchor.userSize) <= 0.01 * anchor.userSize { return nil }
        return ContentOperation("Tf", [name, PdfNumber(anchor.userSize * at.fontSize / at.userSize)], 0, 0)
    }

    // Operators that set the font of the anchor (and widen the spaces of a justified line) for the new text of a line,
    // and the ones that put the line's own state back.
    private static func normalize(_ font: ContentOperation?, _ at: EditGlyph, _ extraWord: Double) throws -> (before: [UInt8]?, after: [UInt8]?) {
        let before = ContentWriter()
        var parts: StateParts = []
        if let font {
            before.add(font)
            parts.insert(.font)
        }
        if extraWord != 0 {
            before.wordSpacing(at.wordSpacing + extraWord)
            parts.insert(.wordSpacing)
        }
        let after = ContentWriter()
        try placeOf(at).states.at(at.op + 1).replay(after, parts)
        return (before.length > 0 ? before.toArray() : nil, after.length > 0 ? after.toArray() : nil)
    }

    // Per-space word spacing that fills the room left on a justified line; nil when no space takes it.
    private static func justifyWord(_ pieces: [EditPiece], _ slack: Double, _ at: EditGlyph) -> Double? {
        let spaces = pieces.filter { $0.code32 && $0.font == nil && $0.bytes.count == 1 }.count
        if spaces == 0 || slack <= 0.01 { return nil }
        return slack / at.unitX / at.scale / Double(spaces)
    }

    // Lines after the ones the block had: their own text objects behind the one the block ends in.
    private func addLines(_ place: Place, _ lines: [Line], _ anchor: EditGlyph, _ anchorFont: ContentOperation?,
                          _ extra: [(pieces: [EditPiece], start: Double, last: Bool)], _ spacing: Double) throws {
        let reference = lines[lines.count - 1].first
        let unitOps = place.unit.operations
        let lastOp = lines.map { line in line.glyphs.map { $0.op }.max() ?? 0 }.max() ?? 0
        var et = -1
        var i = lastOp + 1
        while i < unitOps.count {
            if unitOps[i].operator == "ET" {
                et = i
                break
            }
            i += 1
        }
        let w = ContentWriter()
        w.raw("")
        if et < 0 { w.op("ET") }
        w.save()
        try place.states.at(reference.op + 1).replay(w, .all)
        let font = Self.fontFor(anchor, anchorFont, reference)
        if let font { w.add(font) }
        let (ux, uy) = reference.direction
        let referenceStart = reference.origin.x * ux + reference.origin.y * uy
        for e in 0..<extra.count {
            let (pieces, start, _) = extra[e]
            let along = start - referenceStart, down = Double(e + 1) * spacing
            let tm = Self.moved(reference, ux * along + uy * down, uy * along - ux * down)
            w.beginText().textMatrix(tm)
            let items = try TextBuilder.items(Self.placeOf(reference), reference, pieces, current: font ?? place.states.at(reference.op).font)
            w.raw(Latin1.string(ShowPatch.write(items, false)))
            w.endText()
        }
        w.restore()
        let at = et >= 0 ? unitOps[et].end : unitOps[lastOp].end
        batch.insert(place, at, w.toArray())
    }

    /// The text matrix that puts a glyph's origin where the origin of `g` is moved
    /// to by (dx, dy) in user space: Tm' = Tm CTM T CTM^-1, since the glyph is drawn at scale Tm CTM.
    private static func moved(_ g: EditGlyph, _ dx: Double, _ dy: Double) -> PdfMatrix {
        let ctm = g.ctm
        let inverse = ctm.invert() ?? PdfMatrix.identity
        return g.textMatrix.multiply(ctm).multiply(PdfMatrix.translate(dx, dy)).multiply(inverse)
    }

    // Greedy line breaking at spaces; a word wider than the room is broken between characters.
    // The line being filled is number firstLine plus the lines made so far, which is what measures it.
    private static func wrap(_ pieces: [EditPiece], _ room: Double, _ firstLine: Int, _ measure: (EditPiece, Int) -> Double) -> [[EditPiece]] {
        var lines: [[EditPiece]] = []
        var line: [EditPiece] = []
        var pending: [EditPiece] = []
        var lineWidth = 0.0, pendingWidth = 0.0
        func w(_ p: EditPiece) -> Double { measure(p, firstLine + lines.count) }
        func flush() {
            lines.append(line)
            line = []
            pending = []
            lineWidth = 0
            pendingWidth = 0
        }
        var i = 0
        while i < pieces.count {
            if pieces[i].isSpace {
                if !line.isEmpty {
                    pending.append(pieces[i])
                    pendingWidth += w(pieces[i])
                }
                i += 1
                continue
            }
            var end = i
            while end < pieces.count && !pieces[end].isSpace { end += 1 }
            let word = Array(pieces[i..<end])
            var wordWidth = 0.0
            for piece in word { wordWidth += w(piece) }
            if !line.isEmpty && lineWidth + pendingWidth + wordWidth > room { flush() }
            if !line.isEmpty {
                line.append(contentsOf: pending)
                lineWidth += pendingWidth
            }
            pending = []
            pendingWidth = 0
            for piece in word {
                let width = w(piece)
                if !line.isEmpty && lineWidth + width > room { flush() }
                line.append(piece)
                lineWidth += width
            }
            i = end
        }
        lines.append(line)
        return lines
    }

    func align(_ block: TextObject, _ alignment: TextAlignment) throws {
        let lines = try linesOf(block)
        let left = lines.map { $0.start }.min() ?? 0, right = lines.map { $0.end }.max() ?? 0
        for k in 0..<lines.count {
            let line = lines[k]
            let width = line.end - line.start
            let target: Double
            switch alignment {
            case .center: target = (left + right) / 2 - width / 2
            case .right: target = right - width
            default: target = left
            }
            let delta = target - line.start
            let everything = line.glyphs.flatMap { [$0] + $0.twins }
            let spaces = alignment == .justify && k < lines.count - 1 ? line.glyphs.filter { $0.character.isSpace }.count : 0
            let slack = right - left - width
            let justify = spaces > 0 && slack > 0.01
            if abs(delta) > 0.01 || justify { try shiftGlyphs(everything, delta, justify ? Self.spacesBefore(line) : nil, justify ? slack / Double(spaces) : 0) }
            if !justify { continue }
            for run in streamRuns(everything, .wordSpacing) {
                guard let first = run.first, let last = run.last else { continue }
                if !Self.balanced(first.unit, first.op, last.op) { throw EditConflictException(EditingText.unbalanced) }
                let set = ContentWriter().wordSpacing(first.wordSpacing + slack / first.unitX / first.scale / Double(spaces))
                let restore = ContentWriter()
                try Self.placeOf(last).states.at(last.op + 1).replay(restore, .wordSpacing)
                try patchOf(first).insert(first.element, first.offset, [ShowOps(set.toArray())])
                try patchOf(last).insert(last.element, last.offset + last.length, [ShowOps(restore.toArray())])
            }
        }
    }

    // The spaces ahead of each glyph of a line, its twins' included.
    private static func spacesBefore(_ line: Line) -> [EditGlyph: Int] {
        var before: [EditGlyph: Int] = [:]
        var count = 0
        for g in line.glyphs {
            for each in [g] + g.twins { before[each] = count }
            if g.character.isSpace { count += 1 }
        }
        return before
    }

    // A Td works from the line matrix, which a shift in a string does not move, so each string that starts at a
    // new position is shifted on its own, by what the word spacing added to the line before it.
    private func shiftGlyphs(_ glyphs: [EditGlyph], _ shift: Double, _ spacesBefore: [EditGlyph: Int]?, _ perSpace: Double) throws {
        for group in groupedByRun(glyphs) {
            var last: EditGlyph?
            for g in inStreamOrder(group.glyphs) {
                let amount = shift + Double(spacesBefore?[g] ?? 0) * perSpace
                if (last == nil || !Self.sameRun(last ?? g, g)) && abs(amount) > 0.01 {
                    try patchOf(g).insert(g.element, g.offset, [ShowShift(-Self.shiftAmount(g, amount))])
                }
                last = g
            }
        }
    }

    func space(_ block: TextObject, _ spacing: Double) throws {
        let lines = try linesOf(block)
        let old = block.lineSpacing
        if lines.count < 2 || old <= 0 || spacing <= 0 { throw EditConflictException(EditingText.noText) }
        for k in 1..<lines.count {
            for run in streamRuns(lines[k].glyphs.flatMap { [$0] + $0.twins }, .rise) {
                guard let first = run.first, let last = run.last else { continue }
                if !Self.balanced(first.unit, first.op, last.op) { throw EditConflictException(EditingText.unbalanced) }
                let m = first.textMatrix.multiply(first.ctm)
                let vertical = (m.c * m.c + m.d * m.d).squareRoot()
                let (ux, uy) = first.direction
                let side = m.c * -uy + m.d * ux
                // A line with no usable direction is left alone.
                let sign = side > 0 ? 1 : side < 0 ? -1 : 0
                if vertical < 1e-9 || sign == 0 { continue }
                let set = ContentWriter().op("Ts", first.rise + Double(sign * k) * (old - spacing) / vertical)
                let restore = ContentWriter()
                try Self.placeOf(last).states.at(last.op + 1).replay(restore, .rise)
                try patchOf(first).insert(first.element, first.offset, [ShowOps(set.toArray())])
                try patchOf(last).insert(last.element, last.offset + last.length, [ShowOps(restore.toArray())])
            }
        }
    }
}
