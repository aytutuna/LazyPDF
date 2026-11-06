import Foundation

// Twin of windows/LazyPDF.Core/Export/PlainTextWriter.cs: the plain text of an `ExportDocument`: paragraphs apart by a
// blank line, list items marked, table cells joined by tabs, a form feed after each page.

private typealias Xml = ExportXml

public enum PlainTextWriter {
    public static func make(_ document: ExportDocument) throws -> String {
        let sb = ExportBuilder()
        var counters: [ListLevel: Int] = [:]
        for page in document.pages {
            var previous: ExportParagraph?
            for block in page.blocks {
                try Xml.checkLength(sb)
                switch block {
                case let listed as ExportParagraph where listed.item != nil:
                    guard let item = listed.item else { continue }
                    if let before = previous?.item, before.listId != item.listId { sb.append("\n") }
                    for key in counters.keys where key.list == item.listId && key.level > item.level { counters[key] = nil }
                    let number = counters[ListLevel(list: item.listId, level: item.level)] ?? (item.level == 0 ? max(1, item.number) : 1)
                    counters[ListLevel(list: item.listId, level: item.level)] = number + 1
                    sb.append(" ", 2 * item.level).append(item.ordered ? Xml.i(number) + ". " : "- ").append(listed.text).append("\n")
                    previous = listed
                    continue
                case let paragraph as ExportParagraph:
                    if previous != nil { sb.append("\n") }
                    sb.append(paragraph.text).append("\n")
                case let table as ExportTable:
                    if previous != nil { sb.append("\n") }
                    for row in table.rows {
                        try Xml.checkLength(sb)
                        sb.append(row.map { ExportString.replace(ExportString.replace($0, "\t", " "), "\n", " ") }.joined(separator: "\t")).append("\n")
                    }
                default:
                    continue
                }
                previous = nil
                sb.append("\n")
            }
            if previous != nil { sb.append("\n") }
            sb.append("\u{0C}")
        }
        try Xml.checkLength(sb)
        return sb.text
    }
}
