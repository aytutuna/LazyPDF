import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Stamps/StampsGolden.cs. One line of input is "<op> <words>" (the format is at the top of
// stamps-input.txt): Bates numbers, date formats, header and footer tokens, JPEG headers, and whole stamped documents. A
// document is shown as every object of the file, streams decoded (a JPEG only by its length), because the deflate of the two
// sides is not the same one; what the stamper reports and lists comes first. The date lines are formatted by .NET in the golden
// file and by DateTimeFormat.swift here.
enum StampsGolden {
    private static let day: DateTimeOffset = {
        guard let value = DateTimeOffset(valid: 2026, 3, 9, 14, 5, 7, ticks: 1_234_567, offsetMinutes: 180) else {
            preconditionFailure("The golden day is valid.")
        }
        return value
    }()

    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
            let space = line.firstIndex(of: " ")
            let op = space.map { String(line[..<$0]) } ?? line
            let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
            output += "> \(line)\n"
            for result in try self.op(op, String(decoding: Golden.unescape(rest), as: UTF8.self)) { output += "< \(result)\n" }
        }
        return output
    }

    private static func op(_ op: String, _ rest: String) throws -> [String] {
        switch op {
        case "bates": return [bates(rest)]
        case "date": return [dateOp(rest)]
        case "expand": return [show(StampTokens.expand(rest, values()))]
        case "jpeg": return [jpeg(rest)]
        case "stamp": return try stamp(rest)
        default: return ["unknown op \(op)"]
        }
    }

    // prefix|suffix|digits|number
    private static func bates(_ rest: String) -> String {
        let p = rest.components(separatedBy: "|")
        return show(BatesSpec(prefix: p[0], suffix: p[1], digits: Int(p[2]) ?? 0).format(Int(p[3]) ?? 0))
    }

    // culture|format: the fixed day.
    private static func dateOp(_ rest: String) -> String {
        guard let bar = rest.firstIndex(of: "|") else { return "format error" }
        let culture = CultureInfo(String(rest[..<bar]))
        guard let text = try? day.toString(String(rest[rest.index(after: bar)...]), culture) else { return "format error" }
        return show(text)
    }

    private static func values() -> StampTokens.Values {
        StampTokens.Values(page: 7, pages: 20, bates: "B-000007", spec: HeaderFooterSpec(date: day, fileName: "report.pdf", bates: BatesSpec()))
    }

    private static func jpeg(_ hex: String) -> String {
        let digits = Array(hex.utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i + 1 < digits.count {
            bytes.append(UInt8(String(decoding: digits[i...i + 1], as: UTF8.self), radix: 16) ?? 0)
            i += 2
        }
        guard let found = PdfImageWriter.tryReadJpegHeader(bytes) else { return "none" }
        return "\(found.width) \(found.height) \(found.components)"
    }

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
                    result += "\\u" + String(format: "%04x", UInt32(unit))
                } else {
                    result.unicodeScalars.append(Unicode.Scalar(unit) ?? " ")
                }
            }
        }
        return result
    }

    private static func dump(_ document: PdfDocument) throws -> String {
        var result: [String] = []
        for number in document.objectNumbers {
            let text: String
            switch document.get(number) {
            case let s as PdfStream where (s.dictionary["Filter"] as? PdfName)?.value == "DCTDecode":
                text = "stream \(s.dictionary) | jpeg \(s.data?.count ?? 0)"
            case let s as PdfStream:
                text = "stream \(s.dictionary) | \(show(Latin1.string(try document.data(s))))"
            case let value?:
                text = value.description
            case nil:
                text = "null"
            }
            result.append("\(number): \(text)")
        }
        return result.joined(separator: "\n")
    }

    private static func report(_ run: StampRun) -> String {
        "run \(run.id) \(run.pages) \(run.nextBates) [\(run.missing.map { String($0) }.joined(separator: ","))]"
    }

    private static func list(_ stamper: PdfStamper) -> [String] {
        stamper.list().map {
            "info \($0.id) \($0.kind.name) \($0.label.map { show($0) } ?? "-") \($0.behind ? "True" : "False") [\($0.pages.map { String($0) }.joined(separator: ","))]"
        }
    }

    private static func stamp(_ name: String) throws -> [String] {
        let jpeg = StampKit.jpeg
        var lines: [String] = []
        let document: PdfDocument
        let stamper: PdfStamper
        switch name {
        case "wm-text":
            document = try StampKit.doc(2)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addWatermark(WatermarkSpec(text: "CONFIDENTIAL"))))
        case "wm-lines":
            document = try StampKit.doc(1)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addWatermark(WatermarkSpec(
                text: "LONGER LINE\r\nAB\u{0C}c",
                fontStyle: [.bold, .italic],
                color: StampColor(1, 0, 0),
                opacity: 0.5,
                rotation: 30,
                scale: 0.4,
                anchor: .topRight,
                offsetX: 5,
                offsetY: 7))))
        case "wm-image":
            document = try StampKit.doc(1)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addWatermark(WatermarkSpec(
                image: try XCTUnwrap(try PdfImageWriter.addJpeg(document, jpeg)),
                opacity: 0.6,
                rotation: -20,
                scale: 0.5,
                anchor: .bottomLeft))))
        case "wm-layer":
            document = try StampKit.doc(2)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addWatermark(WatermarkSpec(text: "LAYER", behind: true, layerName: "Mark \u{E7}"))))
        case "wm-pages":
            document = try StampKit.doc(4)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addWatermark(WatermarkSpec(text: "SOME", anchor: .bottom, pages: [2, 0, 9, -1, 2]))))
        case "bg-color":
            document = try StampKit.doc(2)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addBackground(BackgroundSpec(color: StampColor(1, 1, 0.8)))))
        case "bg-fits":
            document = try StampKit.doc(3)
            stamper = PdfStamper(document)
            let image = try XCTUnwrap(try PdfImageWriter.addJpeg(document, jpeg))
            lines.append(report(try stamper.addBackground(BackgroundSpec(image: image, fit: .cover, pages: [0]))))
            lines.append(report(try stamper.addBackground(BackgroundSpec(image: image, fit: .contain, pages: [1]))))
            lines.append(report(try stamper.addBackground(BackgroundSpec(image: image, fit: .stretch, pages: [2]))))
        case "bg-both":
            document = try StampKit.doc(1)
            stamper = PdfStamper(document)
            let pixels = try PdfImageWriter.addRgba(document, 2, 2, [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 9, 9, 9, 255])
            lines.append(report(try stamper.addBackground(BackgroundSpec(color: .gray(0.9), image: pixels, opacity: 0.5, layerName: "Back"))))
        case "hf-basic":
            document = try StampKit.doc(2)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addHeaderFooter(HeaderFooterSpec(
                header: HeaderFooterBand("HL", "HC", "HR"),
                footer: HeaderFooterBand("FL", "FC", "FR"),
                fontStyle: .italic,
                fontSize: 9,
                color: .gray(0.25),
                marginX: 30,
                marginTop: 20,
                marginBottom: 25))))
        case "hf-tokens":
            document = try StampKit.doc(3)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addHeaderFooter(HeaderFooterSpec(
                header: HeaderFooterBand("{page}/{pages}", "{date} {date:dd MMMM yyyy}", "{date:bad'} {file}"),
                footer: HeaderFooterBand("{bates}", "{nope} {", "(x)\\y"),
                startNumber: 5,
                date: day,
                culture: CultureInfo("en-GB"),
                fileName: "report.pdf",
                bates: BatesSpec(prefix: "B-", suffix: ".x", digits: 4, start: 41)))))
        case "hf-evenodd":
            document = try StampKit.doc(4)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addHeaderFooter(HeaderFooterSpec(
                header: HeaderFooterBand("", "", "odd"),
                footer: HeaderFooterBand("", "{page}", ""),
                evenHeader: HeaderFooterBand("even", "", ""),
                evenFooter: HeaderFooterBand(),
                pages: [0, 1, 2]))))
        case "rotated":
            document = try StampKit.pages([
                (keys: "/Rotate 90", content: "BT /F1 12 Tf 50 50 Td (a) Tj ET"),
                (keys: "/Rotate 180", content: "BT /F1 12 Tf 50 50 Td (b) Tj ET"),
                (keys: "/UserUnit 2", content: "BT /F1 12 Tf 50 50 Td (c) Tj ET"),
                (keys: "/CropBox [10 20 110 220] /Rotate 270", content: "BT /F1 12 Tf 50 50 Td (d) Tj ET"),
            ])
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addBackground(BackgroundSpec(color: .gray(0.95)))))
            lines.append(report(try stamper.addWatermark(WatermarkSpec(text: "SIDE", rotation: 45))))
            lines.append(report(try stamper.addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("", "AB", ""), footer: HeaderFooterBand("CD", "", "{page}")))))
        case "unbalanced":
            document = try StampKit.pages([
                (keys: "", content: "q 2 0 0 2 10 10 cm 0 1 0 rg BT /F1 12 Tf 50 50 Td (a) Tj ET"),
                (keys: "", content: "BT /F1 12 Tf 50 50 Td (b) Tj ET Q Q Q"),
                (keys: "", content: "/Span BMC q BT /F1 12 Tf 50 50 Td (c) Tj"),
                (keys: "", content: "q q q q"),
            ])
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addWatermark(WatermarkSpec(text: "S", rotation: 20))))
            lines.append(report(try stamper.addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("S", "", "")))))
            lines.append(report(try stamper.addBackground(BackgroundSpec(color: .black))))
        case "update-remove":
            document = try StampKit.doc(3)
            stamper = PdfStamper(document)
            let first = try stamper.addWatermark(WatermarkSpec(text: "OLD", opacity: 0.2, layerName: "L"))
            lines.append(report(first))
            lines.append(report(try stamper.addHeaderFooter(HeaderFooterSpec(footer: HeaderFooterBand("", "{page}", "")))))
            lines.append(report(try stamper.addBackground(BackgroundSpec(color: .black, pages: [0, 2]))))
            lines.append(report(try stamper.update(first.id, WatermarkSpec(text: "NEW", opacity: 0.8, pages: [1]))))
            lines += list(stamper)
            lines.append("removed \(stamper.remove(2))")
            lines.append("removed again \(stamper.remove(2))")
        case "remove-all":
            document = try StampKit.doc(2)
            stamper = PdfStamper(document)
            lines.append(report(try stamper.addWatermark(WatermarkSpec(text: "A", layerName: "One"))))
            lines.append(report(try stamper.addWatermark(WatermarkSpec(text: "B", behind: true, layerName: "Two"))))
            lines.append(report(try stamper.addHeaderFooter(HeaderFooterSpec(header: HeaderFooterBand("h", "", "")))))
            lines.append("removed \(stamper.removeAll())")
        default:
            return ["unknown stamp \(name)"]
        }
        lines += list(stamper)
        lines += try dump(document).components(separatedBy: "\n")
        return lines
    }
}
