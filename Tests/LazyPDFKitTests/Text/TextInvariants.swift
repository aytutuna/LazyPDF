import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextInvariants.cs.

enum TextInvariants {
    static func check(_ page: TextPage) -> String? {
        var expectedLine = 0, next = 0
        for line in page.lines {
            if line.index != expectedLine || line.range.start != next || line.range.end <= line.range.start { return "line ranges do not tile the characters" }
            expectedLine += 1
            next = line.range.end
        }
        if next != page.chars.count { return "lines do not cover all characters" }
        for i in 0..<page.chars.count {
            let c = page.chars[i]
            let q = c.quad
            if c.index != i || !(q.x0 + q.y0 + q.x1 + q.y1 + q.x2 + q.y2 + q.x3 + q.y3).isFinite { return "character with a bad index or box" }
            if c.line < 0 || c.line >= page.lines.count || !(page.lines[c.line].range.start <= i && i < page.lines[c.line].range.end) { return "character outside its line" }
        }
        if page.words.contains(where: { $0.range.isEmpty || page.chars[$0.range.start].word != $0.index }) { return "bad word" }
        if page.blocks.reduce(0, { $0 + $1.lines.count }) != page.lines.count { return "blocks do not cover all lines" }
        _ = page.text
        _ = TextSelection.of(page, TextRange(0, page.chars.count)).quads()
        return nil
    }
}
