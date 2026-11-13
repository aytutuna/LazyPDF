import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Content/ShapingGolden.cs. The font is Tests/Fixtures/golden/shaping/script.ttf and
// the cases are lines of lines-input.txt: "line <base> <text>" shapes one line, "wrap <base> <width> <text>" breaks a
// text at <width> points of ten point text and dumps each line. <base> is auto, 0 or 1. Code points are printed as hex.
enum ShapingGolden {
    private final class OneFont: FontSource {
        let data: [UInt8]
        init(_ data: [UInt8]) { self.data = data }
        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(data) }
    }

    static func font(file: String = #filePath) throws -> [UInt8] {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url = url.appendingPathComponent("Fixtures").appendingPathComponent("golden").appendingPathComponent("shaping").appendingPathComponent("script.ttf")
        return [UInt8](try Data(contentsOf: url))
    }

    private static func n(_ v: Double) -> String { PdfNumber(v).text }

    private static func points(_ text: String) -> String {
        text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    private static func level(_ token: String) -> Int { token == "auto" ? BidiParagraph.auto : Int(token) ?? 0 }

    static func dump(_ font: [UInt8], _ input: String) throws -> String {
        var out = ""
        func l(_ s: String) { out += s + "\n" }
        let file = FontFile(font)
        let measure = TrueTypeFont.tryParse(font)!
        let shaper = CmapShaper()
        for row in input.components(separatedBy: "\n") {
            if row.isEmpty || row.hasPrefix("#") { continue }
            let wrap = row.hasPrefix("wrap")
            let parts = row.split(separator: " ", maxSplits: wrap ? 3 : 2, omittingEmptySubsequences: false).map(String.init)
            let text = parts[parts.count - 1]
            let draw = try PdfFontEmbedder(try PdfDocument.open(TestPdf.simple(1)), OneFont(font)).add("Script Sans", [], [text])!
            if parts[0] == "line" {
                let line = LineShaper(file, shaper, measure, nil).shape(text, level(parts[1]))
                l("line \(parts[1]) \(points(text))")
                l("  rtl \(line.rightToLeft ? "True" : "False") actual \(line.needsActualText ? "True" : "False") width \(n(line.width))")
                let glyphs = line.glyphs.map { g in
                    "\(g.shaped.glyph):\(n(g.shaped.advance)):\(n(g.shaped.xOffset)):\(n(g.shaped.yOffset)):\(g.start)-\(g.end)\(g.mirrored ? "m" : "")"
                }
                l("  glyphs \(glyphs.joined(separator: " "))")
                l("  text \(points(line.actualText))")
            } else {
                let lines = draw.wrap(text, 10, Double(parts[2]) ?? 0, rightToLeft: parts[1] == "auto" ? nil : parts[1] == "1")
                l("wrap \(parts[1]) \(parts[2]) \(points(text))")
                for line in lines {
                    l("  \(points(line))")
                    let hex = draw.encode(line).map { String(format: "%02X", $0) }.joined()
                    l("    width \(n(draw.width(line, 10))) rtl \(draw.isRightToLeft(line) ? "True" : "False") encode \(hex)")
                }
            }
        }
        return out
    }
}
