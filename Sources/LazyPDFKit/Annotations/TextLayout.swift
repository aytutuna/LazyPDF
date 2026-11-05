import Foundation

// Twin of windows/LazyPDF.Core/Annotations/TextLayout.cs: breaks paragraphs of formatted runs into lines no wider than a
// box, measuring with the fonts that will draw them.

struct Piece {
    let run: TextRun
    let font: PdfDrawFont
    var text: String
    var width: Double
}

struct TextLine {
    let pieces: [Piece]
    let width: Double
    let ascent: Double
    let height: Double
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
            var pieces: [Piece] = []
            var width = 0.0
            for run in paragraph {
                let font = try fontFor(run.format)
                for token in tokens(run.text) {
                    let bare = font.width(trimEnd(token), run.format.size)
                    if !pieces.isEmpty && width + bare > maxWidth {
                        finish(&lines, &pieces, &width)
                        if lines.count >= maxLines { return lines }
                    }
                    if bare > maxWidth {
                        for chunk in chunks(trimEnd(token), font, run.format.size, maxWidth) {
                            if !pieces.isEmpty { finish(&lines, &pieces, &width) }
                            pieces.append(Piece(run: run, font: font, text: chunk, width: font.width(chunk, run.format.size)))
                            width = pieces[pieces.count - 1].width
                        }
                        continue
                    }
                    let full = font.width(token, run.format.size)
                    pieces.append(Piece(run: run, font: font, text: token, width: full))
                    width += full
                }
            }
            finish(&lines, &pieces, &width)
        }
        return lines
    }

    private static func finish(_ lines: inout [TextLine], _ pieces: inout [Piece], _ width: inout Double) {
        if let last = pieces.last, last.text.unicodeScalars.last == " " {
            let trimmed = trimEnd(last.text)
            pieces[pieces.count - 1].text = trimmed
            pieces[pieces.count - 1].width = last.font.width(trimmed, last.run.format.size)
        }
        let total = pieces.reduce(0.0) { $0 + $1.width }
        let ascent = pieces.map { $0.font.ascent * $0.run.format.size }.max() ?? 0
        let height = pieces.map { $0.font.lineHeight($0.run.format.size) }.max() ?? 0
        lines.append(TextLine(pieces: pieces, width: total, ascent: ascent, height: height))
        pieces.removeAll()
        width = 0
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
