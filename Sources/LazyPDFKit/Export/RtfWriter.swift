import Foundation

// Twin of windows/LazyPDF.Core/Export/RtfWriter.cs: the Rich Text Format file of an `ExportDocument`: text outside ASCII
// as \u escapes, so Turkish and every other script survive. The C# verbatim strings are Swift raw strings.

private typealias Xml = ExportXml

public enum RtfWriter {
    public static func make(_ document: ExportDocument) throws -> String {
        let (width, height) = DocxWriter.paperTwips(document)
        let (top, right, bottom, left) = DocxWriter.marginsTwips(document, width, height)
        let content = width - left - right
        let sb = ExportBuilder(#"{\rtf1\ansi\ansicpg1252\uc1\deff0{\fonttbl{\f0\fswiss Calibri;}}"#)
        if let title = document.title, !title.isEmpty { sb.append(#"{\info{\title "#).append(text(title)).append("}}") }
        sb.append(#"\paperw"#).append(Xml.i(width)).append(#"\paperh"#).append(Xml.i(height))
        if width > height { sb.append(#"\landscape"#) }
        sb.append(#"\margl"#).append(Xml.i(left)).append(#"\margr"#).append(Xml.i(right)).append(#"\margt"#).append(Xml.i(top)).append(#"\margb"#).append(Xml.i(bottom)).append("\n")

        var counters: [ListLevel: Int] = [:]
        for page in document.pages {
            if page.index != document.pages[0].index { sb.append(#"\page"#).append("\n") }
            for block in page.blocks {
                try Xml.checkLength(sb, Xml.encoded(block, true))
                switch block {
                case let paragraph as ExportParagraph:
                    self.paragraph(sb, paragraph, &counters)
                case let table as ExportTable:
                    try self.table(sb, table, content)
                case let picture as ExportPicture:
                    self.picture(sb, picture, content)
                default:
                    break
                }
            }
        }
        sb.append("}")
        try Xml.checkLength(sb)
        return sb.text
    }

    private static func paragraph(_ sb: ExportBuilder, _ paragraph: ExportParagraph, _ counters: inout [ListLevel: Int]) {
        sb.append(#"\pard"#)
        if paragraph.heading > 0 { sb.append(#"\sb240\sa80"#) } else { sb.append(#"\sa120"#) }
        if let item = paragraph.item {
            sb.append(#"\li"#).append(Xml.i(720 + 360 * item.level)).append(#"\fi-360 "#)
            for key in counters.keys where key.list == item.listId && key.level > item.level { counters[key] = nil }
            let number = counters[ListLevel(list: item.listId, level: item.level)] ?? (item.level == 0 ? max(1, item.number) : 1)
            counters[ListLevel(list: item.listId, level: item.level)] = number + 1
            sb.append(item.ordered ? Xml.i(number) + "." : #"\u8226?"#).append(#"\tab "#)
        }
        for run in paragraph.runs {
            let size = paragraph.heading > 0 ? max(run.size, 12) : run.size
            sb.append(#"{\fs"#).append(Xml.i(ExportString.round(size * 2)))
            if run.bold || paragraph.heading > 0 { sb.append(#"\b"#) }
            if run.italic { sb.append(#"\i"#) }
            sb.append(" ").append(text(run.text)).append("}")
        }
        sb.append(#"\par"#).append("\n")
    }

    private static func table(_ sb: ExportBuilder, _ table: ExportTable, _ content: Int) throws {
        let columns = min(table.columns, DocxWriter.maxTableColumns)
        if columns == 0 { return }
        let share = DocxWriter.shares(table, columns)
        let total = share.reduce(0, +)
        for row in table.rows {
            try Xml.checkLength(sb)
            sb.append(#"\trowd\trgaph108"#)
            var edge = 0.0
            for c in 0..<columns {
                edge += share[c] / total * Double(content)
                sb.append(#"\clbrdrt\brdrs\brdrw10\clbrdrl\brdrs\brdrw10\clbrdrb\brdrs\brdrw10\clbrdrr\brdrs\brdrw10\cellx"#).append(Xml.i(ExportString.round(edge)))
            }
            for c in 0..<columns {
                sb.append(#"\pard\intbl\fs20 "#).append(text(DocxWriter.cell(row, c, columns))).append(#"\cell"#)
            }
            sb.append(#"\row"#).append("\n")
        }
        sb.append(#"\pard\par"#).append("\n")
    }

    private static func picture(_ sb: ExportBuilder, _ picture: ExportPicture, _ content: Int) {
        var widthTwips = picture.bounds.width * 20, heightTwips = picture.bounds.height * 20
        if widthTwips > Double(content) {
            heightTwips *= Double(content) / widthTwips
            widthTwips = Double(content)
        }
        sb.append(#"\pard{\pict"#).append(picture.image.isJpeg ? #"\jpegblip"# : #"\pngblip"#).append(#"\picw"#).append(Xml.i(picture.image.width)).append(#"\pich"#).append(Xml.i(picture.image.height))
            .append(#"\picwgoal"#).append(Xml.i(ExportString.round(widthTwips))).append(#"\pichgoal"#).append(Xml.i(ExportString.round(heightTwips))).append("\n")
        let digits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(picture.image.data.count * 2)
        for b in picture.image.data {
            hex.append(digits[Int(b >> 4)])
            hex.append(digits[Int(b & 15)])
        }
        sb.append(String(decoding: hex, as: UTF8.self)).append(#"}\par"#).append("\n")
    }

    private static func text(_ text: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        for unit in text.utf16 {
            switch unit {
            case 0x5C, 0x7B, 0x7D:
                out.append(0x5C)
                out.append(UInt8(truncatingIfNeeded: unit))
            case 0x09: out.append(contentsOf: Array(#"\tab "#.utf8))
            case 0x0A: out.append(contentsOf: Array(#"\line "#.utf8))
            case 0x0D: break
            case 0x20..<0x7F: out.append(UInt8(truncatingIfNeeded: unit))
            case 0..<0x20: break
            default:
                // (short)c: a unit from 0x8000 up reads as negative.
                out.append(contentsOf: Array(#"\u"#.utf8))
                out.append(contentsOf: Array(String(Int16(truncatingIfNeeded: unit)).utf8))
                out.append(0x3F)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
