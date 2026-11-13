import Foundation

// Twin of windows/LazyPDF.Core/Annotations/TextLayout.cs: breaks paragraphs of formatted runs into lines no wider than a
// box, measuring with the fonts that will draw them. Lines are broken on the logical text; a paragraph with
// right-to-left characters then gets its bidi levels resolved (the base direction is the first strong character's)
// and each line cut into directional pieces in display order.

/// A stretch of one run set in one font. `offset` is where it starts in the paragraph's text, in UTF-16 units; with
/// `rightToLeft` it is a right-to-left run of the line and is drawn as one.
struct Piece {
    let run: TextRun
    let font: PdfDrawFont
    var text: String
    var width: Double
    var offset = 0
    var rightToLeft = false
}

/// A line of pieces in display order. `rightToLeft`: the paragraph runs right to left, so the line starts on the right.
struct TextLine {
    let pieces: [Piece]
    let width: Double
    let ascent: Double
    let height: Double
    var rightToLeft = false
}

enum TextLayout {
    private static let maxLines = 5_000

    static func layout(_ paragraphs: [[TextRun]], _ maxWidth: Double, _ blank: TextFormat,
                       _ fontFor: (TextFormat) throws -> PdfDrawFont) throws -> [TextLine] {
        var lines: [TextLine] = []
        for paragraph in paragraphs {
            if lines.count >= maxLines { break }
            if paragraph.isEmpty {
                let font = try fontFor(blank)
                lines.append(TextLine(pieces: [], width: 0, ascent: font.ascent * blank.size, height: font.lineHeight(blank.size)))
                continue
            }
            let whole = paragraph.map { $0.text }.joined()
            let bidi = Scripts.needsBidi(whole) ? BidiParagraph(whole) : nil
            var pieces: [Piece] = []
            var width = 0.0
            var runStart = 0
            for run in paragraph {
                let font = try fontFor(run.format)
                var tokenStart = runStart
                for token in tokens(run.text) {
                    var offset = tokenStart
                    tokenStart += token.utf16.count
                    let bare = font.width(trimEnd(token), run.format.size)
                    if !pieces.isEmpty && width + bare > maxWidth {
                        finish(&lines, &pieces, &width, bidi)
                        if lines.count >= maxLines { return lines }
                    }
                    if bare > maxWidth {
                        for chunk in chunks(trimEnd(token), font, run.format.size, maxWidth) {
                            if !pieces.isEmpty { finish(&lines, &pieces, &width, bidi) }
                            pieces.append(Piece(run: run, font: font, text: chunk, width: font.width(chunk, run.format.size), offset: offset))
                            offset += chunk.utf16.count
                            width = pieces[pieces.count - 1].width
                        }
                        continue
                    }
                    let full = font.width(token, run.format.size)
                    pieces.append(Piece(run: run, font: font, text: token, width: full, offset: offset))
                    width += full
                }
                runStart += run.text.utf16.count
            }
            finish(&lines, &pieces, &width, bidi)
        }
        return lines
    }

    private static func finish(_ lines: inout [TextLine], _ pieces: inout [Piece], _ width: inout Double, _ bidi: BidiParagraph?) {
        if let last = pieces.last, last.text.unicodeScalars.last == " " {
            let trimmed = trimEnd(last.text)
            pieces[pieces.count - 1].text = trimmed
            pieces[pieces.count - 1].width = last.font.width(trimmed, last.run.format.size)
        }
        let shown = bidi == nil || pieces.isEmpty ? pieces : displayOrder(pieces, bidi!)
        let total = shown.reduce(0.0) { $0 + $1.width }
        let ascent = shown.map { $0.font.ascent * $0.run.format.size }.max() ?? 0
        let height = shown.map { $0.font.lineHeight($0.run.format.size) }.max() ?? 0
        lines.append(TextLine(pieces: shown, width: total, ascent: ascent, height: height, rightToLeft: bidi?.level == 1))
        pieces.removeAll()
        width = 0
    }

    // L1 and L2 on a line of pieces: cut each piece where the level changes, then turn the runs around from the highest level down.
    private static func displayOrder(_ pieces: [Piece], _ bidi: BidiParagraph) -> [Piece] {
        let first = pieces[0].offset
        let last = pieces[pieces.count - 1].offset + pieces[pieces.count - 1].text.utf16.count
        let levels = bidi.lineLevels(first, last)
        var runs: [(piece: Piece, level: Int)] = []
        for piece in pieces where !piece.text.isEmpty {
            let units = Array(piece.text.utf16)
            // A character the algorithm removed (level -1) takes the level of the one before it.
            func levelAt(_ i: Int, _ before: Int) -> Int {
                let l = levels[piece.offset - first + i]
                return l >= 0 ? l : before
            }
            var from = 0
            var current = levelAt(0, bidi.level)
            for i in 1...units.count {
                let next = i < units.count ? levelAt(i, current) : -1
                if next == current { continue }
                let text = String(decoding: units[from..<i], as: UTF16.self)
                let rtl = current & 1 == 1
                var cut = piece
                cut.text = text
                cut.offset = piece.offset + from
                cut.rightToLeft = rtl
                cut.width = piece.font.runWidth(text, rtl, piece.run.format.size)
                runs.append((cut, current))
                from = i
                current = next
            }
        }
        if runs.isEmpty { return [] }
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
        return runs.map { $0.piece }
    }

    // String.TrimEnd() cuts White_Space characters.
    private static func trimEnd(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    // Each word with the spaces after it, so a break falls between words.
    private static func tokens(_ text: String) -> [String] {
        let s = Array(text.unicodeScalars)
        var result: [String] = []
        var start = 0
        for i in 0..<s.count {
            if s[i] != " " || (i + 1 < s.count && s[i + 1] == " ") { continue }
            result.append(String(String.UnicodeScalarView(s[start...i])))
            start = i + 1
        }
        if start < s.count { result.append(String(String.UnicodeScalarView(s[start...]))) }
        return result
    }

    private static func chunks(_ word: String, _ font: PdfDrawFont, _ size: Double, _ maxWidth: Double) -> [String] {
        var result: [String] = []
        var chunk = ""
        for scalar in word.unicodeScalars {
            if !chunk.isEmpty && font.width(chunk + String(scalar), size) > maxWidth {
                result.append(chunk)
                chunk = ""
            }
            chunk.unicodeScalars.append(scalar)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}
