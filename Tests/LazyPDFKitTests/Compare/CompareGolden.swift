import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Compare/CompareGolden.cs. One line of input is "<op> <words>" (the format is at the
// top of compare-input.txt): edit scripts, comparisons of made files and pixel comparisons of made pages, dumped as text.
// Numbers go through PdfNumber, which both sides write alike.
enum CompareGolden {
    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
            let space = line.firstIndex(of: " ")
            let op = space.map { String(line[..<$0]) } ?? line
            let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
            let shown = line.utf16.count > 160 ? String(decoding: Array(line.utf16.prefix(160)), as: UTF16.self) + "..." : line
            output += "> \(shown)\n"
            for result in try self.op(op, rest) { output += "< \(result)\n" }
        }
        return output
    }

    private static func op(_ op: String, _ rest: String) throws -> [String] {
        switch op {
        case "diff": return diff(rest)
        case "compare": return try compare(rest)
        case "pixel": return try pixel(rest)
        default: return ["unknown op \(op)"]
        }
    }

    private static func n(_ v: Double) -> String { PdfNumber(v).text }

    private static func ints(_ text: String) -> [Int] {
        text == "-" ? [] : text.split(separator: " ").compactMap { Int($0) }
    }

    private static func diff(_ rest: String) -> [String] {
        let parts = rest.components(separatedBy: " ;; ")
        let hunks = parts.count > 2 ? SequenceDiff.diff(ints(parts[0]), ints(parts[1]), Int(parts[2]) ?? 2000) : SequenceDiff.diff(ints(parts[0]), ints(parts[1]))
        if hunks.isEmpty { return ["none"] }
        return hunks.map { "hunk \($0.oldStart) \($0.oldCount) \($0.newStart) \($0.newCount)" }
    }

    // "<flags> ;; <before> ;; <after>": flags are i (ignore case), w (white space), h (header and footer) or "-". A file is its
    // pages split by " || ", a page its lines split by " | ", "-" a page with no lines. A line is plain text, "@topic:n" for the n
    // lines CompareKit.page makes, or "{F2 14 1 0 0} text" for a font, a size and a colour.
    private static func file(_ text: String) -> [[CompareLine]] {
        text.components(separatedBy: " || ").map { page in
            page == "-" ? [] : page.components(separatedBy: " | ").flatMap(lines)
        }
    }

    private static func lines(_ line: String) -> [CompareLine] {
        if line.hasPrefix("@") {
            let topic = line.dropFirst().components(separatedBy: ":")
            return CompareKit.page(topic[0], Int(topic[1]) ?? 0).map(CompareKit.l)
        }
        if line.hasPrefix("{"), let close = line.firstIndex(of: "}") {
            let style = line[line.index(after: line.startIndex)..<close].components(separatedBy: " ")
            let text = String(line[line.index(close, offsetBy: 2)...])
            return [CompareLine(text, font: style[0], size: Double(style[1]) ?? 12, color: style.dropFirst(2).joined(separator: " "))]
        }
        return [CompareLine(line)]
    }

    private static func kindName(_ kind: ChangeKind) -> String {
        switch kind {
        case .added: return "Added"
        case .removed: return "Removed"
        case .changed: return "Changed"
        case .moved: return "Moved"
        }
    }

    private static func areaName(_ area: ChangeArea) -> String {
        switch area {
        case .text: return "Text"
        case .format: return "Format"
        case .image: return "Image"
        case .annotation: return "Annotation"
        case .page: return "Page"
        case .document: return "Document"
        }
    }

    private static func compare(_ rest: String) throws -> [String] {
        let parts = rest.components(separatedBy: " ;; ")
        let options = CompareOptions(ignoreCase: parts[0].contains("i"), ignoreWhiteSpace: parts[0].contains("w"), ignoreHeaderFooter: parts[0].contains("h"))
        let before = try CompareKit.open(CompareKit.bytes(file(parts[1])))
        let after = try CompareKit.open(CompareKit.bytes(file(parts[2])))
        let result = try PdfComparer.compare(before, after, options)
        var out = ["pages \(result.oldPageCount) \(result.newPageCount): "
            + result.pages.map { "\($0.oldIndex)/\($0.newIndex)/\(n($0.similarity))\($0.moved ? "/moved" : "")" }.joined(separator: " ")]
        for c in result.changes {
            out.append("change \(kindName(c.kind)) \(areaName(c.area)) \(c.oldPage) \(c.newPage) old=\(Golden.escape(c.oldText)) new=\(Golden.escape(c.newText)) detail=\(c.detail.map { Golden.escape($0) } ?? "-")")
            out.append("  old \(quads(c.oldQuads))")
            out.append("  new \(quads(c.newQuads))")
        }
        let s = result.summary
        out.append("summary \(s.added) \(s.removed) \(s.changed) \(s.moved) | \(s.text) \(s.format) \(s.images) \(s.annotations) \(s.pages) \(s.document) | \(s.wordsAdded) \(s.wordsRemoved)")
        for text in ComparisonReport.toText(result, "old.pdf", "new.pdf").components(separatedBy: "\n") { out.append("text " + Golden.escape(text)) }
        return out
    }

    private static func quads(_ quads: [TextQuad]) -> String {
        quads.map { "[\(n($0.x0)) \(n($0.y0)) \(n($0.x1)) \(n($0.y1)) \(n($0.x2)) \(n($0.y2)) \(n($0.x3)) \(n($0.y3))]" }.joined(separator: " ; ")
    }

    // "<before> ;; <after> ;; <dpi> [;; a]": a page is "text <seed> <scale>" and then "fill x y w h value" and "scan degrees
    // shiftX shiftY noise" in any number, the last scan turning the canvas into the picture; "a" at the end switches the
    // alignment off.
    private static func pixel(_ rest: String) throws -> [String] {
        let parts = rest.components(separatedBy: " ;; ")
        let options = PixelOptions(align: parts.count < 4)
        let result = try PixelComparer.compare(try picture(parts[0]), try picture(parts[1]), Double(parts[2]) ?? 72, options)
        var out: [String] = []
        for d in result.differences { out.append("region \(n(d.region.x)) \(n(d.region.y)) \(n(d.region.width)) \(n(d.region.height)) \(d.pixels)") }
        if out.isEmpty { out.append("regions none") }
        out.append("similarity \(n(result.similarity))")
        out.append("alignment \(n(result.alignment.shiftX)) \(n(result.alignment.shiftY)) \(n(result.alignment.degrees))")
        out.append("overlay \(result.overlay.width) \(result.overlay.height) \(ImageLook.toHexString(Sha256.hash(result.overlay.rgba)))")
        return out
    }

    private static func picture(_ spec: String) throws -> PdfRgbaImage {
        let t = spec.split(separator: " ").map(String.init)
        var canvas: PixelPages.Canvas?
        var scanned: PdfRgbaImage?
        var i = 0
        while i < t.count {
            switch t[i] {
            case "text":
                canvas = PixelPages.text(scale: Double(t[i + 2]) ?? 1, seed: Int(t[i + 1]) ?? 5)
                i += 3
            case "fill":
                try XCTUnwrap(canvas).fill(Int(t[i + 1]) ?? 0, Int(t[i + 2]) ?? 0, Int(t[i + 3]) ?? 0, Int(t[i + 4]) ?? 0, UInt8(t[i + 5]) ?? 0)
                i += 6
            default:
                scanned = PixelPages.scan(try XCTUnwrap(canvas), Double(t[i + 1]) ?? 0, Int(t[i + 2]) ?? 0, Int(t[i + 3]) ?? 0, noise: Int(t[i + 4]) ?? 0)
                i += 5
            }
        }
        return try scanned ?? XCTUnwrap(canvas).toImage()
    }
}
