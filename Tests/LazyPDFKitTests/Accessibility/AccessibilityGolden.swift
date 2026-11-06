import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Accessibility/AccessibilityGolden.cs. One line of input is "<op> <fixture>" (the format is
// at the top of accessibility-input.txt): trees read from hand-made files, the check list, a file tagged by AutoTagger and a
// tree written after a move, and the three patterns Swift matches by hand where the C# has a Regex (list markers, page numbers
// and language tags) with the folded text of a line. A file is shown as every object with the trailer, streams decoded, so that the numbers the tagger
// gives to new objects and the sequences it writes into the content are pinned; the compressed bytes themselves are not, as
// Swift writes its own deflate.
enum AccessibilityGolden {
    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
            let space = line.firstIndex(of: " ")
            let op = space.map { String(line[..<$0]) } ?? line
            let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
            output += "> \(line)\n"
            for result in try self.op(op, rest) { output += "< \(result)\n" }
        }
        return output
    }

    private static func op(_ op: String, _ rest: String) throws -> [String] {
        switch op {
        case "marker": return [marker(text(rest))]
        case "pagenumber": return [bool(TagText.isPageNumber(text(rest)))]
        case "signature": return [TagText.signature(text(rest)).map { show($0) } ?? "none"]
        case "langtag": return [try languageTag(text(rest))]
        default: break
        }
        guard let file = fixture(rest) else { return ["unknown fixture \(rest)"] }
        let document = try PdfDocument.open(file)
        switch op {
        case "tree": return tree(document)
        case "check": return try check(document)
        case "tag": return try tag(document)
        case "move": return try move(document)
        default: return ["unknown op \(op)"]
        }
    }

    private static func text(_ rest: String) -> String { String(decoding: Golden.unescape(rest), as: UTF8.self) }

    private static func marker(_ text: String) -> String {
        let found = TagText.markerOf(text).map { "\($0.numbered ? "numbered" : "bullet") \($0.length)" } ?? "none"
        return "\(found) lone=\(bool(TagText.isLoneMarker(text)))"
    }

    // Whether setLanguage takes the text, which is whether the language tag pattern matches it.
    private static func languageTag(_ text: String) throws -> String {
        let document = try PdfDocument.open(TaggedFile.build())
        do {
            _ = try AccessibilityChecker.fix(document, .setLanguage, text)
            return "valid"
        } catch is ArgumentException {
            return "invalid"
        }
    }

    // tagged | tagged-bad | report <pages> | rotated <pages> | page <escaped content of the only page>
    private static func fixture(_ spec: String) -> [UInt8]? {
        let space = spec.firstIndex(of: " ")
        let kind = space.map { String(spec[..<$0]) } ?? spec
        let arg = space.map { String(spec[spec.index(after: $0)...]) } ?? ""
        switch kind {
        case "tagged": return TaggedFile.build()
        case "tagged-bad":
            return TaggedFile.build({ o in
                o[10] = "<</Type /StructElem /S /Weird /P 9 0 R /Pg 3 0 R /K 0>>"
                o[11] = "<</Type /StructElem /S /H3 /P 9 0 R /Pg 3 0 R /K 1>>"
                o[12] = "<</Type /StructElem /S /Figure /P 9 0 R /Pg 3 0 R /K 2>>"
            }, catalog: "")
        case "report": return Int(arg).map { AccessKit.report($0) }
        case "rotated": return Int(arg).map { AccessKit.build($0, AccessKit.reportPage, pageEntries: "/Rotate 90") }
        case "page":
            let content = Latin1.string(Golden.unescape(arg))
            return AccessKit.build(1) { _ in content }
        default: return nil
        }
    }

    private static func tree(_ document: PdfDocument) -> [String] {
        let tree = StructureTree.read(document)
        return dumpTree(tree) + ["order " + show(ReadingOrder.export(document, tree))]
    }

    private static func check(_ document: PdfDocument) throws -> [String] {
        try AccessibilityChecker.check(document).items.map { item in
            let places = item.where.map { "\($0.pageIndex):\($0.element?.number ?? -1)" }.joined(separator: ",")
            return "\(item.rule) \(item.status) \(item.fix) [\(places)] \(show(item.name)) | \(show(item.message))"
        }
    }

    private static func tag(_ document: PdfDocument) throws -> [String] {
        let result = try AutoTagger.tag(document, AutoTagOptions("en-US"))
        let figures = result.figuresWithoutAlt.map { "\($0.pageIndex):\($0.reference.number)" }.joined(separator: ",")
        let summary = "result \(bool(result.alreadyTagged)) pages=\(result.pages) skipped=\(result.skippedPages) headings=\(result.headings) "
            + "paragraphs=\(result.paragraphs) lists=\(result.lists) tables=\(result.tables) figures=\(result.figures) artifacts=\(result.artifacts) [\(figures)]"
        return [summary] + (try dump(document)) + tree(document)
    }

    private static func move(_ document: PdfDocument) throws -> [String] {
        if StructureTree.read(document) == nil { _ = try AutoTagger.tag(document) }
        guard let tree = StructureTree.read(document), let root = tree.roots.first, let last = root.children.last else { return ["no tree"] }
        try tree.move(last, root, 0)
        try tree.write(document)
        return try dump(document) + dumpTree(StructureTree.read(document))
    }

    private static func dumpTree(_ tree: StructureTree?) -> [String] {
        guard let tree else { return ["no tree"] }
        var lines: [String] = []
        for root in tree.roots { lines += dumpElement(root, 0) }
        for entry in tree.roleMap.entries { lines.append("role \(entry.key) \(entry.value)") }
        for entry in tree.classMap.entries { lines.append("class \(entry.key) \(entry.value.description)") }
        for entry in tree.parentTree { lines.append("parent \(entry.key) \(entry.value.description)") }
        lines.append("truncated " + bool(tree.isTruncated))
        return lines
    }

    private static func dumpElement(_ element: StructElement, _ depth: Int) -> [String] {
        let pad = String(repeating: " ", count: depth * 2)
        var lines = ["\(pad)\(show(element.type)) page=\(element.pageIndex) ref=\(element.reference?.number ?? -1) title=\(opt(element.title)) alt=\(opt(element.alt)) "
            + "lang=\(opt(element.lang)) actual=\(opt(element.actualText)) id=\(opt(element.id))"]
        for kid in element.kids {
            if let child = kid as? StructElement {
                lines += dumpElement(child, depth + 1)
            } else if let content = kid as? StructContent {
                lines.append("\(pad)  content page=\(content.pageIndex) mcid=\(content.mcid) stream=\(content.stream?.number ?? -1)")
            } else if let target = kid as? StructObject {
                lines.append("\(pad)  object page=\(target.pageIndex) target=\(target.target.number)")
            }
        }
        return lines
    }

    private static func dump(_ document: PdfDocument) throws -> [String] {
        var lines = ["trailer \(document.trailer)"]
        for number in document.objectNumbers {
            let text: String
            switch document.get(number) {
            case let stream as PdfStream: text = "stream \(withoutLength(stream)) | \(show(Latin1.string(try document.data(stream))))"
            case let value?: text = value.description
            case nil: text = "null"
            }
            lines.append("\(number): \(text)")
        }
        return lines
    }

    // /Length is that of the compressed bytes, which differ between the two deflate writers.
    private static func withoutLength(_ stream: PdfStream) -> PdfDictionary {
        let copy = stream.dictionary.copy()
        copy.remove("Length")
        return copy
    }

    private static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    private static func opt(_ text: String?) -> String { text.map { show($0) } ?? "~" }

    private static func show(_ text: String) -> String {
        var result = ""
        for unit in text.utf16 {
            switch unit {
            case 0x5C: result += "\\\\"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            default:
                if unit < 0x20 || unit >= 0x7F {
                    result += "\\u" + String(format: "%04x", Int(unit))
                } else if let scalar = Unicode.Scalar(unit) {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}
