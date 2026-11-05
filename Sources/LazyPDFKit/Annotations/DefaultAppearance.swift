import Foundation

// Twin of windows/LazyPDF.Core/Annotations/DefaultAppearance.cs: the /DA string of a free text annotation (ISO 32000-1
// 12.7.3.3): font name and size, and a fill colour.

enum DefaultAppearance {
    private static let fonts: [String: (family: String, bold: Bool, italic: Bool)] = [
        "Helv": ("Helvetica", false, false), "HeBo": ("Helvetica", true, false), "HeOb": ("Helvetica", false, true), "HeBO": ("Helvetica", true, true),
        "TiRo": ("Times New Roman", false, false), "TiBo": ("Times New Roman", true, false), "TiIt": ("Times New Roman", false, true), "TiBI": ("Times New Roman", true, true),
        "Cour": ("Courier New", false, false), "CoBo": ("Courier New", true, false), "CoOb": ("Courier New", false, true), "CoBO": ("Courier New", true, true),
    ]

    static func isStandard(_ font: String) -> Bool { fonts[font] != nil }

    static func parse(_ da: String?) -> (font: String?, size: Double?, color: [Double]?) {
        guard let da, !da.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else { return (nil, nil, nil) }
        var font: String?
        var size: Double?
        var color: [Double]?
        var operands: [String] = []
        let separators = Set(" \t\r\n".unicodeScalars)
        for part in da.unicodeScalars.split(whereSeparator: { separators.contains($0) }) {
            let token = String(String.UnicodeScalarView(part))
            switch token {
            case "Tf" where operands.count >= 2:
                font = String(operands[operands.count - 2].drop(while: { $0 == "/" }))
                size = InvariantNumbers.parseDouble(operands[operands.count - 1])
                operands.removeAll()
            case "g", "rg", "k":
                let count = token == "g" ? 1 : token == "rg" ? 3 : 4
                if operands.count >= count {
                    let values = operands.suffix(count).map { InvariantNumbers.parseDouble($0) }
                    if values.allSatisfy({ $0 != nil }) { color = values.compactMap { $0 } }
                }
                operands.removeAll()
            default:
                operands.append(token)
                if operands.count > 16 { operands.removeFirst() }
            }
        }
        return (font, size, color)
    }

    /// The format a DA font name stands for; names outside the standard set keep the format as it is.
    static func formatOf(_ font: String, _ current: TextFormat) -> TextFormat {
        guard let known = fonts[font] else { return current }
        var format = current
        format.family = known.family
        format.bold = known.bold
        format.italic = known.italic
        return format
    }

    static func build(_ format: TextFormat) -> String {
        let family = format.family.lowercased()
        let name: String
        if family.hasPrefix("times") {
            name = format.bold ? (format.italic ? "TiBI" : "TiBo") : format.italic ? "TiIt" : "TiRo"
        } else if family.hasPrefix("courier") {
            name = format.bold ? (format.italic ? "CoBO" : "CoBo") : format.italic ? "CoOb" : "Cour"
        } else {
            name = format.bold ? (format.italic ? "HeBO" : "HeBo") : format.italic ? "HeOb" : "Helv"
        }
        let color = format.color.map { PdfNumber($0).text }.joined(separator: " ")
        let op = format.color.count == 1 ? "g" : format.color.count == 4 ? "k" : "rg"
        return "/\(name) \(PdfNumber(format.size).text) Tf \(color) \(op)"
    }

    /// The /DS CSS the text was set with, which keeps the family and style a /DA name cannot say.
    static func buildStyle(_ format: TextFormat, _ alignment: Int) -> String {
        let align = alignment == 1 ? "center" : alignment == 2 ? "right" : "left"
        let rgb = format.color.count == 3 ? format.color : format.color.count == 1 ? [format.color[0], format.color[0], format.color[0]] : [0, 0, 0]
        let hex = "#" + rgb.map { v -> String in
            let byte = Int((min(max(v.isNaN ? 0 : v, 0), 1) * 255).rounded(.toNearestOrEven))
            return String(format: "%02lX", byte)
        }.joined()
        let size = InvariantNumbers.twoDecimals(format.size)
        return "font-family: \(format.family); font-size: \(size)pt; font-weight: \(format.bold ? "bold" : "normal"); "
            + "font-style: \(format.italic ? "italic" : "normal"); text-align: \(align); color: \(hex)"
    }
}
