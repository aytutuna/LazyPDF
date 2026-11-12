import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Office/OfficeLayoutSpec.cs: reads layout-input.txt, the cases of
// Tests/Fixtures/golden/office-layout, into documents.

enum OfficeLayoutSpec {
    /// The bundled fonts in fonts/ at the repo root, found by family and style as the apps do.
    final class BundledFonts: FontSource {
        private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fonts")
        private var files: [String: FontFile?] = [:]

        func find(_ family: String, _ style: FontStyles) -> FontFile? {
            let suffix: String
            switch (style.contains(.bold), style.contains(.italic)) {
            case (true, true): suffix = "BoldItalic"
            case (true, false): suffix = "Bold"
            case (false, true): suffix = "Italic"
            default: suffix = "Regular"
            }
            let name = family.replacingOccurrences(of: " ", with: "") + "-" + suffix
            if let known = files[name] { return known }
            let folder = Self.folder.appendingPathComponent(family.split(separator: " ")[0].lowercased())
            let file = (try? Data(contentsOf: folder.appendingPathComponent(name + ".ttf"))).map { FontFile([UInt8]($0)) }
            files[name] = .some(file)
            return file
        }
    }

    static func fonts() -> FontSource { OfficeFontSource(installed: nil, bundled: BundledFonts()) }

    static func read(_ input: String) throws -> [(name: String, document: LayoutDocument)] {
        var cases: [(name: String, document: LayoutDocument)] = []
        var document: LayoutDocument?
        var section: LayoutSection?
        var band = "body"
        var paragraph: (keys: [String: String], runs: [LayoutRun])?

        func flush() {
            guard let p = paragraph, let section else { return }
            let made = LayoutParagraph()
            made.runs = p.runs
            switch p.keys["align"] {
            case "center": made.align = .center
            case "right": made.align = .right
            case "justify": made.align = .justify
            default: made.align = .left
            }
            made.left = number(p.keys, "left")
            made.right = number(p.keys, "right")
            made.firstLine = number(p.keys, "first")
            made.before = number(p.keys, "before")
            made.after = number(p.keys, "after")
            made.lineSpacing = p.keys["line"] != nil ? number(p.keys, "line") : 1
            switch p.keys["rule"] {
            case "exact": made.rule = .exact
            case "atleast": made.rule = .atLeast
            default: made.rule = .multiple
            }
            made.keepWithNext = p.keys["keep"] != nil
            made.pageBreakBefore = p.keys["break"] != nil
            made.widowControl = p.keys["nowidow"] == nil
            if band == "header" { section.header.append(made) } else if band == "footer" { section.footer.append(made) } else { section.blocks.append(made) }
            paragraph = nil
        }

        for line in input.components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix("# ") { continue }
            let command = line.components(separatedBy: " ")[0]
            let rest = line.unicodeScalars.count > command.unicodeScalars.count ? String(line.unicodeScalars.dropFirst(command.unicodeScalars.count + 1)) : ""
            switch command {
            case "case":
                flush()
                document = LayoutDocument()
                cases.append((rest, document!))
                section = nil
            case "section":
                flush()
                section = LayoutSection()
                document!.sections.append(section!)
                band = "body"
            case "page":
                let n = rest.components(separatedBy: " ").map { Double($0)! }
                section!.page = LayoutGeometry(width: n[0], height: n[1], top: n[2], right: n[3], bottom: n[4], left: n[5],
                                               headerDistance: n.count > 6 ? n[6] : 36, footerDistance: n.count > 7 ? n[7] : 36)
            case "band":
                flush()
                band = rest
            case "p":
                flush()
                paragraph = (keys(rest), [])
            case "r":
                let bar = rest.range(of: "|")!
                let k = keys(String(rest[..<bar.lowerBound]))
                var text = String(rest[bar.upperBound...])
                if text.unicodeScalars.first == " " { text = String(String.UnicodeScalarView(text.unicodeScalars.dropFirst())) }
                let run = LayoutRun()
                run.text = unescape(text)
                run.family = k["font"]?.replacingOccurrences(of: "_", with: " ") ?? OfficeFontSource.defaultFamily
                run.size = k["size"] != nil ? number(k, "size") : 11
                run.bold = k["b"] != nil
                run.italic = k["i"] != nil
                run.underline = k["u"] != nil
                run.strike = k["s"] != nil
                run.color = k["color"].map { Int($0, radix: 16)! } ?? 0
                run.highlight = k["hl"].map { Int($0, radix: 16)! }
                run.shift = number(k, "shift")
                switch k["field"] {
                case "page": run.field = .pageNumber
                case "pages": run.field = .pageCount
                default: run.field = .none
                }
                paragraph!.runs.append(run)
            case "pagebreak":
                flush()
                section!.blocks.append(LayoutPageBreak())
            case "skip":
                let w = rest.components(separatedBy: " ")
                document!.skipped.append(SkippedFeature(w[0], Int(w[1])!))
            default:
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: line])
            }
        }
        flush()
        return cases
    }

    private static func keys(_ text: String) -> [String: String] {
        var keys: [String: String] = [:]
        for word in text.components(separatedBy: " ") where !word.isEmpty {
            if let eq = word.firstIndex(of: "=") {
                keys[String(word[..<eq])] = String(word[word.index(after: eq)...])
            } else {
                keys[word] = ""
            }
        }
        return keys
    }

    private static func number(_ keys: [String: String], _ key: String) -> Double {
        keys[key].map { Double($0)! } ?? 0
    }

    static func unescape(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            if scalars[i] != "\\" {
                result.append(scalars[i])
                i += 1
                continue
            }
            i += 1
            switch scalars[i] {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "f": result.append("\u{0C}")
            case "u":
                let digits = String(String.UnicodeScalarView(scalars[(i + 1)...(i + 4)]))
                result.append(Unicode.Scalar(UInt32(digits, radix: 16)!)!)
                i += 4
            default: result.append(scalars[i])
            }
            i += 1
        }
        return String(result)
    }

    static func escape(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            switch c {
            case "\\": result.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": result.append(contentsOf: "\\n".unicodeScalars)
            case "\t": result.append(contentsOf: "\\t".unicodeScalars)
            case "\u{0C}": result.append(contentsOf: "\\f".unicodeScalars)
            default:
                if c.value < 0x20 { result.append(contentsOf: ("\\u" + String(format: "%04x", c.value)).unicodeScalars) } else { result.append(c) }
            }
        }
        return String(result)
    }
}
