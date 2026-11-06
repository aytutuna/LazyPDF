import Foundation

// Twin of windows/LazyPDF.Core/Export/MarkdownWriter.cs: the Markdown (CommonMark with GFM tables) of an
// `ExportDocument`. A rule separates the pages.

private typealias Xml = ExportXml

public enum MarkdownWriter {
    /// With `embedImages`, pictures are written as data URIs; otherwise they are left out, Markdown having no place for
    /// the file.
    public static func make(_ document: ExportDocument, embedImages: Bool = false) throws -> String {
        let sb = ExportBuilder()
        var counters: [ListLevel: Int] = [:]
        var firstPage = true
        for page in document.pages {
            if !firstPage { sb.append("---\n\n") }
            firstPage = false
            var previous: ExportParagraph?
            for block in page.blocks {
                try Xml.checkLength(sb, embedImages ? Xml.encoded(block, false) : 0)
                if let before = previous?.item {
                    let now = (block as? ExportParagraph)?.item
                    if !(now != nil && now?.listId == before.listId) { sb.append("\n") }
                }
                switch block {
                case let listed as ExportParagraph where listed.item != nil:
                    if let item = listed.item { self.item(sb, listed, item, &counters) }
                    previous = listed
                    continue
                case let paragraph as ExportParagraph:
                    if previous?.item != nil { sb.append("\n") }
                    self.paragraph(sb, paragraph)
                case let table as ExportTable:
                    if previous?.item != nil { sb.append("\n") }
                    try self.table(sb, table)
                case let picture as ExportPicture where embedImages:
                    if previous?.item != nil { sb.append("\n") }
                    sb.append("![\(ExportText.image(1))](data:\(picture.image.mimeType);base64,\(Data(picture.image.data).base64EncodedString()))\n\n")
                default:
                    continue
                }
                previous = block as? ExportParagraph
            }
            if previous?.item != nil { sb.append("\n") }
        }
        try Xml.checkLength(sb)
        var text = sb.text.unicodeScalars
        while text.last == "\n" { text.removeLast() }
        return String(text) + (sb.length > 0 ? "\n" : "")
    }

    private static func paragraph(_ sb: ExportBuilder, _ paragraph: ExportParagraph) {
        if paragraph.heading > 0 {
            sb.append("#", paragraph.heading).append(" ").append(escape(ExportTrim.both(ExportString.replace(paragraph.text, "\t", " ")))).append("\n\n")
            return
        }
        sb.append(guardStart(inline(paragraph.runs))).append("\n\n")
    }

    private static func item(_ sb: ExportBuilder, _ paragraph: ExportParagraph, _ item: ExportListItem, _ counters: inout [ListLevel: Int]) {
        for key in counters.keys where key.list == item.listId && key.level > item.level { counters[key] = nil }
        let number = counters[ListLevel(list: item.listId, level: item.level)] ?? (item.level == 0 ? max(1, item.number) : 1)
        counters[ListLevel(list: item.listId, level: item.level)] = number + 1
        sb.append(" ", 3 * item.level).append(item.ordered ? Xml.i(number) + ". " : "- ").append(inline(paragraph.runs)).append("\n")
    }

    private static func table(_ sb: ExportBuilder, _ table: ExportTable) throws {
        for r in 0..<table.rows.count {
            try Xml.checkLength(sb)
            sb.append("|")
            for cell in table.rows[r] { sb.append(" ").append(escape(ExportString.replace(ExportString.replace(cell, "\n", " "), "\t", " "))).append(" |") }
            sb.append("\n")
            if r == 0 {
                sb.append("|")
                for _ in 0..<table.columns { sb.append(" --- |") }
                sb.append("\n")
            }
        }
        sb.append("\n")
    }

    private static func inline(_ runs: [ExportRun]) -> String {
        var sb = ""
        for run in runs {
            let text = ExportString.replace(run.text, "\t", " ")
            let (lead, core, trail) = ExportString.edges(text)
            if core.isEmpty {
                sb += text
                continue
            }
            let mark = (run.bold ? "**" : "") + (run.italic ? "*" : "")
            sb += lead + mark + escape(core) + String(mark.reversed()) + trail
        }
        return ExportTrim.end(sb)
    }

    // A line that would start a heading, bullet, rule or numbered item gets its first mark escaped.
    private static func guardStart(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.first else { return text }
        let dash = scalars.count >= 2 && first == "-" && scalars[1] == " "
        let rule = scalars.count >= 3 && first == "-" && scalars[1] == "-" && scalars[2] == "-"
        if first == "#" || first == "+" || first == "=" || dash || rule { return "\\" + text }
        var digits = 0
        while digits < scalars.count && ExportChar.isAsciiDigit(scalars[digits]) { digits += 1 }
        if digits > 0 && digits <= 9 && digits < scalars.count && (scalars[digits] == "." || scalars[digits] == ")") {
            return String(String.UnicodeScalarView(scalars[..<digits])) + "\\" + String(String.UnicodeScalarView(scalars[digits...]))
        }
        return text
    }

    private static func escape(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if "\\`*_[]<>|~".unicodeScalars.contains(c) { out.append("\\") }
            out.append(c)
        }
        return String(out)
    }
}
