import Foundation

// Twin of windows/LazyPDF.Core/Export/HtmlWriter.cs: one self-contained HTML file of an `ExportDocument`: pictures
// inline as data URIs, styles in the head.

private typealias Xml = ExportXml

public enum HtmlWriter {
    private static let head = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>"

    /// The text reflowed: headings, paragraphs with `strong` and `em`, nested lists, tables and figures, one `section` a page.
    public static func reflowed(_ document: ExportDocument) throws -> String {
        let sb = ExportBuilder(head)
        sb.append(Xml.escape(document.title ?? ExportText.page(1))).append("</title>\n<style>\n")
            .append("body{font-family:Georgia,'Times New Roman',serif;line-height:1.5;max-width:46em;margin:2em auto;padding:0 1em}\n")
            .append("section+section{border-top:1px solid #ccc;margin-top:2em;padding-top:1em}\n")
            .append("table{border-collapse:collapse;margin:1em 0}td{border:1px solid #999;padding:.2em .5em;vertical-align:top}\n")
            .append("img{max-width:100%;height:auto}\n</style>\n</head>\n<body>\n")
        var lists: [String] = []
        var listId = 0
        func closeLists(_ to: Int) {
            while lists.count > to { sb.append("</li>\n</\(lists.removeLast())>\n") }
        }

        for page in document.pages {
            sb.append("<section id=\"page-\(Xml.i(page.index + 1))\">\n")
            for block in page.blocks {
                try Xml.checkLength(sb, Xml.encoded(block, false))
                if let listed = block as? ExportParagraph, let item = listed.item {
                    if !lists.isEmpty && item.listId != listId { closeLists(0) }
                    listId = item.listId
                    let target = lists.isEmpty ? 1 : min(item.level + 1, lists.count + 1)
                    if lists.count >= target {
                        closeLists(target)
                        sb.append("</li>\n")
                    }
                    while lists.count < target {
                        let tag = item.ordered ? "ol" : "ul"
                        lists.append(tag)
                        sb.append("<\(tag)")
                        if item.ordered && lists.count == 1 && item.number > 1 { sb.append(" start=\"\(Xml.i(item.number))\"") }
                        sb.append(">\n")
                    }
                    sb.append("<li>")
                    runs(sb, listed.runs)
                    continue
                }
                closeLists(0)
                switch block {
                case let paragraph as ExportParagraph:
                    let tag = paragraph.heading > 0 ? "h" + Xml.i(paragraph.heading) : "p"
                    sb.append("<\(tag)>")
                    runs(sb, paragraph.runs, paragraph.heading > 0)
                    sb.append("</\(tag)>\n")
                case let table as ExportTable:
                    sb.append("<table>\n")
                    for row in table.rows {
                        try Xml.checkLength(sb)
                        sb.append("<tr>")
                        for cell in row { sb.append("<td>").append(Xml.escape(cell)).append("</td>") }
                        sb.append("</tr>\n")
                    }
                    sb.append("</table>\n")
                case let picture as ExportPicture:
                    sb.append("<p><img src=\"data:\(picture.image.mimeType);base64,\(Data(picture.image.data).base64EncodedString())")
                        .append("\" width=\"\(Xml.i(ExportString.round(picture.bounds.width * 96 / 72)))\" height=\"\(Xml.i(ExportString.round(picture.bounds.height * 96 / 72)))")
                        .append("\" alt=\"\"></p>\n")
                default:
                    break
                }
            }
            closeLists(0)
            sb.append("</section>\n")
        }
        sb.append("</body>\n</html>\n")
        try Xml.checkLength(sb)
        return sb.text
    }

    /// A file that looks like the pages: every text line a `span` at its position in points on a page-sized box, and
    /// nothing else. No pictures.
    public static func fixed(_ document: ExportDocument) throws -> String {
        let sb = ExportBuilder(head)
        sb.append(Xml.escape(document.title ?? ExportText.page(1))).append("</title>\n<style>\n")
            .append("body{background:#888;margin:0;padding:1em 0;font-family:Arial,'Helvetica Neue',sans-serif}\n")
            .append(".page{position:relative;background:#fff;margin:0 auto 1em;overflow:hidden}\n")
            .append(".page span{position:absolute;white-space:pre}\n</style>\n</head>\n<body>\n")
        for page in document.pages {
            sb.append("<div class=\"page\" id=\"page-\(Xml.i(page.index + 1))\" style=\"width:\(Xml.d(page.width))pt;height:\(Xml.d(page.height))pt\">\n")
            for line in page.lines {
                var longest = line.runs.first
                for run in line.runs.dropFirst() where run.text.utf16.count > (longest?.text.utf16.count ?? 0) { longest = run }
                let size = longest?.size ?? 0
                let top = line.bounds.y + (line.bounds.height - size) / 2
                sb.append("<span style=\"left:\(Xml.d(line.bounds.x))pt;top:\(Xml.d(top))pt;font-size:\(Xml.d(size))pt;line-height:\(Xml.d(size))pt\">")
                for run in line.runs {
                    let style = run.bold || run.italic || abs(run.size - size) > 0.6
                    if style {
                        sb.append("<span style=\"position:static")
                        if run.bold { sb.append(";font-weight:bold") }
                        if run.italic { sb.append(";font-style:italic") }
                        if abs(run.size - size) > 0.6 { sb.append(";font-size:\(Xml.d(run.size))pt") }
                        sb.append("\">")
                    }
                    sb.append(Xml.escape(run.text))
                    if style { sb.append("</span>") }
                }
                sb.append("</span>\n")
                try Xml.checkLength(sb)
            }
            sb.append("</div>\n")
        }
        return sb.append("</body>\n</html>\n").text
    }

    private static func runs(_ sb: ExportBuilder, _ runs: [ExportRun], _ heading: Bool = false) {
        for run in runs {
            let text = ExportString.replace(Xml.escape(run.text), "\t", "&emsp;")
            let (lead, core, trail) = ExportString.edges(text)
            if core.isEmpty {
                sb.append(text)
                continue
            }
            // Spaces at the edges stay outside the tags.
            sb.append(lead)
            let bold = run.bold && !heading
            if bold { sb.append("<strong>") }
            if run.italic { sb.append("<em>") }
            sb.append(core)
            if run.italic { sb.append("</em>") }
            if bold { sb.append("</strong>") }
            sb.append(trail)
        }
    }
}
