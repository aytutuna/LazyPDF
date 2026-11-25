import Foundation

// Twin of windows/LazyPDF.Core/Office/Layout/ParagraphLayout.cs: breaks a paragraph into lines at a width, greedy, as
// Word fits them, with no kerning.

final class Atom {
    var code = 0
    var run: LayoutRun
    var runFace: FontFace
    var face: FontFace
    var size = 0.0
    var width = 0.0
    /// For a picture in line: the picture and its height after it was fitted to the line.
    var picture: LayoutPicture?
    var pictureHeight = 0.0
    /// From the left edge of the text area.
    var x = 0.0
    /// Space added after the atom by justification.
    var extra = 0.0
    /// An explicit stop this tab runs to when the text is before it.
    var stop: Double?
    /// The bidi embedding level; odd is right to left. Set only for a paragraph that needs the algorithm.
    var level = 0
    /// Where the atom starts in the text the bidi algorithm ran on.
    var unit = 0

    init(code: Int, run: LayoutRun, face: FontFace, size: Double) {
        self.code = code
        self.run = run
        runFace = face
        self.face = face
        self.size = size
    }

    var isSpace: Bool {
        code == 0x20 || (code >= 0x2000 && code <= 0x200A && code != 0x2007) || code == 0x1680 || code == 0x205F
    }

    var isTab: Bool { code == 0x09 }
    var isNewline: Bool { code == 0x0A }
    var isZeroWidth: Bool { code == 0x200B || Scripts.isBidiControl(code) }
    var isRightToLeft: Bool { level & 1 == 1 }
    /// The left edge of the room the atom takes: justification adds its gap before a right-to-left atom.
    var boxLeft: Double { isRightToLeft ? x - extra : x }
    var boxRight: Double { isRightToLeft ? x + width : x + width + extra }
    /// Takes room (or none) but draws nothing.
    var isBlank: Bool { isSpace || isTab || isNewline || isZeroWidth }
}

final class LayoutLine {
    var atoms: [Atom] = []
    var height = 0.0
    /// From the top of the line.
    var baseline = 0.0
    var start = 0.0

    init(start: Double = 0) {
        self.start = start
    }
}

final class ParagraphLines {
    let source: LayoutParagraph
    var lines: [LayoutLine] = []
    var complexScript = false

    init(_ source: LayoutParagraph) {
        self.source = source
    }

    var height: Double {
        var sum = 0.0
        for line in lines { sum += line.height }
        return sum
    }
}

enum ParagraphLayout {
    private static let tolerance = 0.01
    private static let tabWidth = 36.0

    /// The code point a picture takes in the text; it breaks like an ideograph.
    static let objectCode = 0xFFFC

    /// `maxHeight` is the tallest a picture may be, so that one always fits a page.
    static func run(_ paragraph: LayoutParagraph, _ fonts: LayoutFonts, _ areaWidth: Double, _ maxHeight: Double, _ field: ((LayoutField) -> String)? = nil) throws -> ParagraphLines {
        let result = ParagraphLines(paragraph)
        var bidi = false
        let atoms = try makeAtoms(paragraph, fonts, field, result, &bidi)
        let order = bidi || paragraph.rightToLeft ? bidiText(atoms, paragraph) : nil
        let align = paragraph.rightToLeft ? mirrored(paragraph.align) : paragraph.align
        if let labelTab = paragraph.labelTab, let labelAtom = atoms.first(where: { $0.isTab }) { labelAtom.stop = labelTab }
        let left = max(0, paragraph.left)
        let first = max(0, paragraph.left + paragraph.firstLine)
        let right = max(areaWidth - max(0, paragraph.right), max(left, first) + 1)
        fit(atoms, right - min(left, first), maxHeight, paragraph)
        let justify = align == .justify

        let breaks = LineBreaker.opportunities(atoms.map { $0.code })
        var line = LayoutLine(start: first)
        var x = first
        var i = 0
        while i < atoms.count {
            var end = i + 1
            while end < atoms.count && !breaks[end] { end += 1 }
            var visible = end
            while visible > i && atoms[visible - 1].isBlank && !atoms[visible - 1].isTab { visible -= 1 }

            var reach = x
            for k in i..<visible { reach += step(atoms[k], reach, left, right, place: false) }
            let tooWide = reach > right + tolerance
            if tooWide && !line.atoms.isEmpty {
                try finish(result, line, right, justify: justify, paragraph, align, order, areaWidth, fonts)
                line = LayoutLine(start: left)
                x = left
                continue
            }
            for k in i..<end {
                let atom = atoms[k]
                // A segment wider than the line is cut where it runs out.
                if tooWide && k < visible && !line.atoms.isEmpty && x + step(atom, x, left, right, place: false) > right + tolerance {
                    try finish(result, line, right, justify: justify, paragraph, align, order, areaWidth, fonts)
                    line = LayoutLine(start: left)
                    x = left
                }
                atom.x = x
                x += step(atom, x, left, right, place: true)
                line.atoms.append(atom)
            }
            if atoms[end - 1].isNewline {
                try finish(result, line, right, justify: false, paragraph, align, order, areaWidth, fonts)
                line = LayoutLine(start: left)
                x = left
            }
            i = end
        }
        try finish(result, line, right, justify: false, paragraph, align, order, areaWidth, fonts)
        return result
    }

    // A picture wider or taller than the room shrinks, keeping its shape.
    // The height leaves room for the descent, the multiple spacing and the space around the paragraph, so the line still fits.
    private static func fit(_ atoms: [Atom], _ width: Double, _ height: Double, _ paragraph: LayoutParagraph) {
        var room = height - paragraph.before - paragraph.after
        if paragraph.rule == .multiple && paragraph.lineSpacing > 1 { room /= paragraph.lineSpacing }
        for atom in atoms where atom.picture != nil {
            let limit = room - atom.runFace.descent * atom.size
            let scale = min(1, min(max(1, width) / atom.width, max(1, limit) / atom.pictureHeight))
            atom.width *= scale
            atom.pictureHeight *= scale
        }
    }

    // The width an atom takes at x. A tab runs to the hanging indent or the next default stop, never past the right edge.
    private static func step(_ atom: Atom, _ x: Double, _ left: Double, _ right: Double, place: Bool) -> Double {
        if !atom.isTab { return atom.width }
        var stop = x < left - tolerance ? left : ((x / tabWidth).rounded(.down) + 1) * tabWidth
        if let explicit = atom.stop, x < explicit - tolerance { stop = x < left - tolerance ? min(left, explicit) : explicit }
        let width = max(0, min(stop, max(right, x)) - x)
        if place { atom.width = width }
        return width
    }

    private static func makeAtoms(_ paragraph: LayoutParagraph, _ fonts: LayoutFonts, _ field: ((LayoutField) -> String)?, _ result: ParagraphLines, _ bidi: inout Bool) throws -> [Atom] {
        var atoms: [Atom] = []
        for run in paragraph.runs {
            let face = try faceOf(run, fonts)
            let runSize = size(run)
            if let picture = run.picture {
                let atom = Atom(code: objectCode, run: run, face: face, size: runSize)
                atom.width = picture.width
                atom.picture = picture
                atom.pictureHeight = picture.height
                atoms.append(atom)
                continue
            }
            var text = run.text
            if let field, run.field != .none { text = field(run.field) }
            for scalar in text.unicodeScalars {
                let code = Int(scalar.value)
                if code == 0xAD || code == 0x200C || code == 0x200D || code == 0x2060 || code == 0xFEFF || code == objectCode || (code < 0x20 && code != 0x09 && code != 0x0A)
                    || (code >= 0x7F && code < 0xA0) { continue }
                bidi = bidi || run.rtl || Scripts.needsBidi(code)
                if (code >= 0x0900 && code <= 0x0EFF) || (code >= 0x0F00 && code <= 0x109F) || (code >= 0x1780 && code <= 0x17FF) {
                    result.complexScript = true
                }
                let atom = Atom(code: code, run: run, face: face, size: runSize)
                if !atom.isBlank || atom.isSpace {
                    atom.face = fonts.choose(face, code)
                    atom.width = atom.face.advance(code) * runSize
                }
                atoms.append(atom)
            }
        }
        measureJoined(atoms, fonts.shaper)
        return atoms
    }

    private static func isArabic(_ atom: Atom) -> Bool {
        let c = atom.code
        return atom.picture == nil && ((c >= 0x0600 && c <= 0x06FF) || (c >= 0x0750 && c <= 0x077F) || (c >= 0x08A0 && c <= 0x08FF)
            || (c >= 0xFB50 && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFF))
    }

    // The writer draws an Arabic stretch with the joined glyphs of the shaper, whose advances differ from the isolated
    // letters'. Each glyph's advance goes to the atom its cluster starts in; the rest of a ligature gets none.
    private static func measureJoined(_ atoms: [Atom], _ shaper: Shaper?) {
        guard let shaper else { return }
        var i = 0
        while i < atoms.count {
            if !isArabic(atoms[i]) { i += 1; continue }
            var end = i + 1
            while end < atoms.count && isArabic(atoms[end]) && atoms[end].run === atoms[i].run && atoms[end].face === atoms[i].face { end += 1 }
            var text = ""
            var starts: [Int] = []
            var length = 0
            for k in i..<end {
                starts.append(length)
                text.unicodeScalars.append(Unicode.Scalar(UInt32(atoms[k].code))!)
                length += atoms[k].code > 0xFFFF ? 2 : 1
            }
            if let glyphs = shaper.shape(text, atoms[i].face.file, rightToLeft: true, language: nil) {
                for k in i..<end { atoms[k].width = 0 }
                for glyph in glyphs {
                    let cluster = min(max(glyph.cluster, 0), length - 1)
                    var at = 0
                    while at + 1 < starts.count && starts[at + 1] <= cluster { at += 1 }
                    atoms[i + at].width += glyph.advance / 1000 * atoms[i].size
                }
            }
            i = end
        }
    }

    private static func mirrored(_ align: LayoutAlign) -> LayoutAlign {
        switch align {
        case .left: return .right
        case .right: return .left
        default: return align
        }
    }

    // The text the bidi algorithm runs on: one character an atom (a tab and a line break are neutral), and a right-to-left run
    // inside a left-to-right paragraph embedded, so that the neutral characters in it go with its direction.
    private static func bidiText(_ atoms: [Atom], _ paragraph: LayoutParagraph) -> BidiParagraph {
        var text = String.UnicodeScalarView()
        var units = 0
        var embedded = false
        for atom in atoms {
            let inside = atom.run.rtl && !paragraph.rightToLeft
            if inside != embedded {
                text.append(Unicode.Scalar(inside ? 0x202B : 0x202C)!)
                units += 1
                embedded = inside
            }
            atom.unit = units
            let scalar = Unicode.Scalar(UInt32(atom.isNewline ? 0x20 : atom.code)) ?? Unicode.Scalar(0xFFFD)!
            text.append(scalar)
            units += atom.code > 0xFFFF ? 2 : 1
        }
        if embedded { text.append(Unicode.Scalar(0x202C)!) }
        return BidiParagraph(String(text), baseLevel: paragraph.rightToLeft ? 1 : 0)
    }

    static func faceOf(_ run: LayoutRun, _ fonts: LayoutFonts) throws -> FontFace {
        var style: FontStyles = []
        if run.bold { style.insert(.bold) }
        if run.italic { style.insert(.italic) }
        guard let face = fonts.find(run.family, style) ?? fonts.find(OfficeFontSource.defaultFamily, style) else {
            throw InvalidOperationException(ExportText.noFont)
        }
        return face
    }

    static func size(_ run: LayoutRun) -> Double { run.size > 0 ? min(run.size, 1000) : 11 }

    private static func finish(_ result: ParagraphLines, _ line: LayoutLine, _ right: Double, justify: Bool, _ paragraph: LayoutParagraph, _ align: LayoutAlign, _ bidi: BidiParagraph?, _ areaWidth: Double, _ fonts: LayoutFonts) throws {
        self.align(line, right, align, justify)
        if let bidi { reorder(line, bidi, paragraph.rightToLeft, areaWidth) }
        try measure(line, paragraph, fonts)
        result.lines.append(line)
    }

    private static func align(_ line: LayoutLine, _ right: Double, _ align: LayoutAlign, _ justify: Bool) {
        guard let ink = line.atoms.lastIndex(where: { !$0.isBlank || $0.isTab }) else { return }
        let room = max(0, right - line.start - (line.atoms[ink].x + line.atoms[ink].width - line.start))
        if align == .center || align == .right {
            let shift = align == .center ? room / 2 : room
            for a in line.atoms { a.x += shift }
        } else if justify && room > 0 && !line.atoms.contains(where: { $0.isTab }) {
            let gaps = line.atoms.prefix(ink).filter { $0.code == 0x20 }.count
            if gaps == 0 { return }
            let extra = room / Double(gaps)
            var shift = 0.0
            for k in 0..<line.atoms.count {
                let a = line.atoms[k]
                a.x += shift
                if k < ink && a.code == 0x20 {
                    a.extra = extra
                    shift += extra
                }
            }
        }
    }

    // The atoms were placed in logical order from the start edge. Put them in display order (L2), left to right, from where the
    // line starts: the left of the text area, or for a right-to-left paragraph the right edge, which the area width gives.
    private static func reorder(_ line: LayoutLine, _ bidi: BidiParagraph, _ rightToLeft: Bool, _ areaWidth: Double) {
        let atoms = line.atoms
        guard let head = atoms.first, let tail = atoms.last else { return }
        let first = head.unit
        let end = tail.unit + (tail.code > 0xFFFF ? 2 : 1)
        let levels = bidi.lineLevels(first, end)
        for atom in atoms {
            let l = levels[atom.unit - first]
            atom.level = l >= 0 ? l : bidi.level
        }

        var visual = Array(0..<atoms.count)
        let highest = atoms.map { $0.level }.max() ?? 0
        let lowestOdd = atoms.filter { $0.isRightToLeft }.map { $0.level }.min() ?? Int.max
        var level = highest
        while level >= lowestOdd {
            var i = 0
            while i < visual.count {
                if atoms[visual[i]].level < level {
                    i += 1
                    continue
                }
                var j = i
                while j + 1 < visual.count && atoms[visual[j + 1]].level >= level { j += 1 }
                visual[i...j].reverse()
                i = j + 1
            }
            level -= 1
        }

        var total = 0.0
        for a in atoms { total += a.width + a.extra }
        var x = rightToLeft ? areaWidth - head.x - total : head.x
        for k in visual {
            let atom = atoms[k]
            atom.x = x + (atom.isRightToLeft ? atom.extra : 0)
            x += atom.width + atom.extra
        }
    }

    // A single-spaced line is the tallest ascent plus the deepest descent, the line gap included; the extra
    // of a larger spacing goes above the text, as in Word.
    private static func measure(_ line: LayoutLine, _ paragraph: LayoutParagraph, _ fonts: LayoutFonts) throws {
        var ascent = 0.0, descent = 0.0
        if !line.atoms.isEmpty {
            for a in line.atoms {
                ascent = max(ascent, (a.picture == nil ? a.runFace.ascent * a.size : a.pictureHeight) + max(0, a.run.shift))
                descent = max(descent, a.runFace.descent * a.size + max(0, -a.run.shift))
            }
        } else {
            let run = paragraph.runs.first ?? LayoutRun()
            let face = try faceOf(run, fonts)
            ascent = face.ascent * size(run)
            descent = face.descent * size(run)
        }
        let natural = ascent + descent
        let spacing = paragraph.lineSpacing > 0 ? paragraph.lineSpacing : 1
        switch paragraph.rule {
        case .exact: line.height = spacing
        case .atLeast: line.height = max(natural, spacing)
        case .multiple: line.height = natural * spacing
        }
        line.baseline = line.height - descent
    }
}
