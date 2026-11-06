import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Export/ExportGolden.cs. One line of input is "<op> <words>" (the format is at the top
// of export-input.txt): pages analysed into the model the writers share, the writers' text, the parts of the Office
// packages, the PNG rows, the numbers of a sheet and what a JPEG header says. A package is shown by the name, size and CRC-32
// of each part as it reads back, because the deflate of the two sides is not the same one. Numbers go through PdfNumber, which
// both sides write alike; text goes through esc, which writes every UTF-16 unit outside printable ASCII as \uXXXX.
enum ExportGolden {
    static func run(_ input: String) throws -> String {
        // English whatever the machine's language is.
        try L10n.english {
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
    }

    private static func op(_ op: String, _ rest: String) throws -> [String] {
        do {
            switch op {
            case "layout": return try writer("model", ExportLayout.analyze(ExportKit.open(content(rest))))
            case "content":
                let space = rest.firstIndex(of: " ") ?? rest.endIndex
                let tail = space == rest.endIndex ? "" : String(rest[rest.index(after: space)...])
                return try writer(String(rest[..<space]), ExportLayout.analyze(ExportKit.open(content(tail))))
            case "report": return try writer(rest, ExportLayout.analyze(ExportKit.report()))
            case "built":
                let space = rest.firstIndex(of: " ") ?? rest.endIndex
                let tail = space == rest.endIndex ? "" : String(rest[rest.index(after: space)...])
                return try writer(tail, built(String(rest[..<space])))
            case "number": return number(text(rest))
            case "jpeg": return jpeg(hex(rest))
            case "place": return place(rest)
            case "png": return try png(rest)
            default: return ["unknown op \(op)"]
            }
        } catch let failure as PdfReadException {
            return ["error \(problemName(failure.problem)) \(failure.message)"]
        }
    }

    private static func problemName(_ problem: PdfReadProblem) -> String {
        switch problem {
        case .notPdf: return "NotPdf"
        case .damaged: return "Damaged"
        case .encrypted: return "Encrypted"
        case .passwordRequired: return "PasswordRequired"
        case .unsupported: return "Unsupported"
        case .certificateRequired: return "CertificateRequired"
        }
    }

    private static func content(_ rest: String) -> String { TestPdf.text(Golden.unescape(rest)) }

    private static func text(_ rest: String) -> String { String(decoding: Golden.unescape(rest), as: UTF8.self) }

    private static func hex(_ text: String) -> [UInt8] {
        let digits = Array(text.utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i + 1 < digits.count {
            bytes.append(UInt8(String(decoding: digits[i...(i + 1)], as: UTF8.self), radix: 16) ?? 0)
            i += 2
        }
        return bytes
    }

    private static func n(_ v: Double) -> String { PdfNumber(v).text }

    private static func b(_ value: Bool) -> String { value ? "1" : "0" }

    private static func box(_ r: DisplayRect) -> String { "[\(n(r.x)) \(n(r.y)) \(n(r.width)) \(n(r.height))]" }

    private static func esc(_ text: String) -> String {
        var out = ""
        for c in text.utf16 {
            switch c {
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default:
                if c < 0x20 || c >= 0x7F {
                    out += "\\u" + String(format: "%04X", Int(c))
                } else {
                    out.unicodeScalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: c)))
                }
            }
        }
        return out
    }

    private static func writer(_ writer: String, _ model: ExportDocument) throws -> [String] {
        switch writer {
        case "model": return self.model(model)
        case "plain": return [esc(try PlainTextWriter.make(model))]
        case "markdown": return [esc(try MarkdownWriter.make(model))]
        case "markdownembed": return [esc(try MarkdownWriter.make(model, embedImages: true))]
        case "htmlreflowed": return [esc(try HtmlWriter.reflowed(model))]
        case "htmlfixed": return [esc(try HtmlWriter.fixed(model))]
        case "rtf": return [esc(try RtfWriter.make(model))]
        case "docx": return try package(DocxWriter.make(model))
        case "xlsx": return try package(XlsxWriter.make(model))
        case "pptx": return try package(PptxWriter.make(model))
        default: return ["unknown writer \(writer)"]
        }
    }

    private static func model(_ d: ExportDocument) -> [String] {
        var lines = ["model title=\(d.title.map(esc) ?? "-") body=\(n(d.bodySize)) left=\(d.picturesLeftOut) pages=\(d.pages.count)"]
        for page in d.pages {
            lines.append("page \(page.index) \(n(page.width)) \(n(page.height)) blocks=\(page.blocks.count) lines=\(page.lines.count) pictures=\(page.pictures.count)")
            for block in page.blocks {
                switch block {
                case let p as ExportParagraph:
                    lines.append("  paragraph heading=\(p.heading) item=\(item(p.item)) \(box(p.bounds)) runs=\(runs(p.runs))")
                case let t as ExportTable:
                    let widths = t.widths.map { $0.map(n).joined(separator: ",") } ?? "-"
                    let cells = t.rows.map { $0.map(esc).joined(separator: "|") }.joined(separator: ";")
                    lines.append("  table ruled=\(b(t.ruled)) \(t.rows.count)x\(t.columns) \(box(t.bounds)) widths=\(widths) cells=\(cells)")
                case let p as ExportPicture:
                    lines.append("  picture \(image(p.image)) \(box(p.bounds))")
                default:
                    lines.append("  unknown block")
                }
            }
            for line in page.lines { lines.append("  line \(box(line.bounds)) runs=\(runs(line.runs))") }
        }
        return lines
    }

    private static func item(_ item: ExportListItem?) -> String {
        guard let item else { return "-" }
        return "\(item.listId),\(b(item.ordered)),\(item.level),\(item.number)"
    }

    private static func runs(_ runs: [ExportRun]) -> String {
        runs.map { "<\(esc($0.text)):\(b($0.bold))\(b($0.italic)):\(n($0.size))>" }.joined(separator: " ")
    }

    // A PNG holds the deflate of the side that wrote it, so it is shown by its size and format only.
    private static func image(_ image: ExportImage) -> String {
        image.isJpeg
            ? "jpeg \(image.width)x\(image.height) bytes=\(image.data.count) crc=\(String(format: "%08X", ExportZip.crc32(image.data)))"
            : "png \(image.width)x\(image.height)"
    }

    private static func package(_ package: [UInt8]) throws -> [String] {
        try ExportZipReader.read(package).map { "\($0.name) \($0.data.count) \(String(format: "%08X", ExportZip.crc32($0.data)))" }
    }

    private static func built(_ name: String) -> ExportDocument {
        func page(_ blocks: [ExportBlock]) -> ExportDocument { ExportDocument("Başlık", [ExportPage(0, 612, 792, blocks, [], [])], 11) }
        func entry(_ text: String, _ level: Int, _ ordered: Bool, _ number: Int) -> ExportParagraph {
            ExportParagraph(DisplayRect(Double(72 + 18 * level), Double(72 + 20 * level), 100, 12), [ExportRun(text, false, false, 11)], 0, ExportListItem(3, ordered, level, number))
        }
        switch name {
        case "turkish":
            return page([
                ExportParagraph(DisplayRect(72, 60, 300, 24), [ExportRun("Başlık & <özet>", true, false, 18)], 2),
                ExportParagraph(DisplayRect(72, 100, 400, 14), [
                    ExportRun("Çağrı ğ Ş ı İ ", false, false, 11),
                    ExportRun("{x} \"q\" ", true, false, 11),
                    ExportRun(" a\\b # * _ | [l] ", false, true, 11),
                    ExportRun("tab\there", true, true, 11),
                ]),
                ExportParagraph(DisplayRect(72, 130, 400, 14), [ExportRun("1. not a list", false, false, 11)]),
                ExportParagraph(DisplayRect(72, 150, 400, 14), [ExportRun("- not a bullet", false, false, 11)]),
            ])
        case "nested":
            return page([
                entry("a", 0, false, 0), entry("b", 1, false, 0), entry("c", 1, false, 0), entry("d", 0, false, 0),
                ExportParagraph(DisplayRect(72, 200, 100, 12), [ExportRun("between", false, false, 11)]),
                entry("five", 0, true, 5), entry("six", 0, true, 6), entry("inner", 2, true, 1),
            ])
        case "special":
            return page([ExportParagraph(DisplayRect(72, 72, 100, 12), [ExportRun("a < b & c > \"d\" \u{1}x\u{FFFE}y\tz\r\nw", false, false, 11)])])
        case "tables":
            return page([
                ExportTable(DisplayRect(72, 72, 300, 40), [["Name", "Qty", "Price"], ["Tea", "3", "4.50"], ["Coffee", "007", "1.234,56"], ["Milk\nsemi", "1e5", "-12"]], [100, 200, 50], true),
                ExportTable(DisplayRect(72, 200, 300, 40), [(0..<70).map { "c\($0)" }, (0..<70).map { String($0) }], nil, false),
            ])
        case "tiny":
            return ExportDocument("t", [ExportPage(0, 30, 40, [ExportPicture(DisplayRect(2, 2, 26, 36), ExportImage(ExportKit.jpeg, true, 8, 6))], [], [])], 11)
        case "pages":
            let jpeg = ExportImage(ExportKit.jpeg, true, 8, 6)
            let one = ExportPage(0, 100, 100, [ExportPicture(DisplayRect(5, 5, 20, 15), jpeg)],
                                 [ExportTextLine(DisplayRect(10, 10, 50, 10), [ExportRun("A", false, false, 10)])], [ExportPicture(DisplayRect(5, 5, 20, 15), jpeg)])
            let two = ExportPage(1, 200, 200, [],
                                 [ExportTextLine(DisplayRect(20, 20, 100, 20), [ExportRun("B", false, true, 20), ExportRun("\tc", true, false, 9.5)])],
                                 [ExportPicture(DisplayRect(40, 40, 60, 45), jpeg)])
            return ExportDocument(nil, [one, two], 10)
        default:
            return ExportDocument(nil, [], 11)
        }
    }

    // number <text>: what the sheet makes of a cell and how it writes the number down.
    private static func number(_ text: String) -> [String] {
        guard let value = XlsxWriter.tryNumber(text) else { return ["text"] }
        return ["number \(XlsxWriter.roundTrip(value))"]
    }

    // jpeg <hex>: the density and the Exif orientation of the header.
    private static func jpeg(_ file: [UInt8]) -> [String] {
        let (x, y) = JpegMeta.density(file)
        return ["density \(n(x)) \(n(y)) orientation \(JpegMeta.orientation(file))"]
    }

    // place <orientation> <w> <h> <x> <y>: where the unit square of the picture goes.
    private static func place(_ rest: String) -> [String] {
        let words = rest.components(separatedBy: " ")
        func d(_ i: Int) -> Double { Double(words[i]) ?? 0 }
        let m = JpegMeta.placement(Int(words[0]) ?? 0, d(1), d(2), d(3), d(4))
        return ["[\(n(m.a)) \(n(m.b)) \(n(m.c)) \(n(m.d)) \(n(m.e)) \(n(m.f))]"]
    }

    // png <kind> <w> <h>: the format and the filtered rows of the PNG, as the deflate gives them back.
    private static func png(_ rest: String) throws -> [String] {
        let words = rest.components(separatedBy: " ")
        let w = Int(words[1]) ?? 0, h = Int(words[2]) ?? 0
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        func byte(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: v) }
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                switch words[0] {
                case "gray": (rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]) = (byte(x * 5 + y * 3), byte(x * 5 + y * 3), byte(x * 5 + y * 3), 255)
                case "flat": (rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]) = (200, 200, 200, 255)
                case "alpha": (rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]) = (byte(x * 7 + y), byte(y * 11), byte((x ^ y) * 13), byte(x * 255 / max(1, w - 1)))
                default: (rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]) = (byte(x * 7 + y), byte(y * 11), byte((x ^ y) * 13), 255)
                }
            }
        }
        let png = try PngWriter.encode(PdfRgbaImage(w, h, rgba))
        var idat: [UInt8] = []
        var pos = 8
        while pos < png.count {
            let length = Int(png[pos]) << 24 | Int(png[pos + 1]) << 16 | Int(png[pos + 2]) << 8 | Int(png[pos + 3])
            if String(decoding: png[(pos + 4)..<(pos + 8)], as: UTF8.self) == "IDAT" { idat += png[(pos + 8)..<(pos + 8 + length)] }
            pos += 12 + length
        }
        let rows = try PdfFilters.inflate(idat)
        let channels = png[25] == 0 ? 1 : png[25] == 2 ? 3 : 4
        let filters = (0..<h).map { String(rows[$0 * (w * channels + 1)]) }.joined()
        return ["type=\(png[25]) filters=\(filters) raw=\(rows.count) crc=\(String(format: "%08X", ExportZip.crc32(rows)))"]
    }
}
