import Foundation

// Twin of windows/LazyPDF.Core/Office/Xlsx/XlsxStylesReader.cs.

/// Reads xl/styles.xml: number format codes, fonts, fills, borders and the cell formats that tie them together.
enum XlsxStylesReader {
    private static let m = XlsxReader.m

    private static let palette: [Int] = [
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
        0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
        0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
        0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
        0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
        0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
    ]

    private static let themeNames = ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"]

    private static let digitRatio: [String: Double] = [
        "calibri": 0.507, "carlito": 0.507, "arial": 0.556, "helvetica": 0.556, "liberation sans": 0.556,
        "times new roman": 0.5, "liberation serif": 0.5, "courier new": 0.6, "liberation mono": 0.6,
        "verdana": 0.636, "tahoma": 0.546, "cambria": 0.55, "caladea": 0.55,
    ]

    static func read(_ root: OfficeXmlElement?, _ theme: DocxTheme, _ limits: XlsxLimits) throws -> XlsxStyles {
        let styles = XlsxStyles()
        if let root, root.uri == m, root.name == "styleSheet" {
            for n in root.child(m, "numFmts")?.elements(m, "numFmt") ?? [] {
                guard let id = XlsxParse.int(n.attribute("numFmtId")), let code = n.attribute("formatCode") else { continue }
                if styles.codes.count >= limits.maxNumberFormats { throw tooMany("number formats") }
                styles.codes[id] = code
            }
            for f in try items(root, "fonts", "font", limits) { styles.fonts.append(readFont(f, theme)) }
            for f in try items(root, "fills", "fill", limits) { styles.fills.append(readFill(f, theme)) }
            for b in try items(root, "borders", "border", limits) { styles.borders.append(readBorder(b, theme)) }
            for x in try items(root, "cellXfs", "xf", limits) { styles.xfs.append(readXf(x)) }
        }
        if styles.fonts.isEmpty { styles.fonts.append(XlsxFont(name: "Calibri", size: 11, bold: false, italic: false, underline: false, strike: false, color: nil)) }
        if styles.fills.isEmpty { styles.fills.append(XlsxFill(color: nil, unsupported: false)) }
        if styles.borders.isEmpty { styles.borders.append(XlsxBorder(left: nil, right: nil, top: nil, bottom: nil)) }
        if styles.xfs.isEmpty {
            styles.xfs.append(XlsxXf(font: 0, fill: 0, border: 0, numberFormatId: 0, horizontal: .general, vertical: .bottom, wrap: false, indent: 0, rotated: false))
        }
        styles.maxDigitWidth = digitWidth(styles.fonts[0])
        return styles
    }

    private static func tooMany(_ what: String) -> PdfReadException {
        PdfReadException(.unsupported, "The workbook has too many \(what).")
    }

    private static func items(_ root: OfficeXmlElement, _ list: String, _ item: String, _ limits: XlsxLimits) throws -> [OfficeXmlElement] {
        let all = root.child(m, list)?.elements(m, item) ?? []
        if all.count > limits.maxStyles { throw tooMany("cell formats") }
        return all
    }

    private static func lower(_ s: String) -> String {
        String(decoding: s.utf16.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }, as: UTF16.self)
    }

    private static func digitWidth(_ font: XlsxFont) -> Int {
        let ratio = digitRatio[lower(font.name)] ?? 0.507
        return max(1, Int((font.size * 96 / 72 * ratio + 0.5).rounded(.down)))
    }

    private static func underline(_ e: OfficeXmlElement?) -> Bool {
        guard let e else { return false }
        return (e.attribute("val") ?? "single") != "none"
    }

    private static func readFont(_ f: OfficeXmlElement, _ theme: DocxTheme) -> XlsxFont {
        func flag(_ name: String) -> Bool { f.child(m, name).map { XlsxParse.flag($0.attribute("val"), true) } ?? false }
        var size = 11.0
        if let s = XlsxParse.double(f.child(m, "sz")?.attribute("val")), s > 0, s <= 409 { size = s }
        var name = "Calibri"
        if let n = f.child(m, "name")?.attribute("val"), !n.isEmpty { name = n }
        return XlsxFont(name: name, size: size, bold: flag("b"), italic: flag("i"), underline: underline(f.child(m, "u")), strike: flag("strike"),
                        color: readColor(f.child(m, "color"), theme))
    }

    /// The font of a rich text run: what the run states, else the font of the cell format.
    static func runFont(_ props: OfficeXmlElement?, _ baseFont: XlsxFont, _ theme: DocxTheme) -> XlsxFont {
        guard let props else { return baseFont }
        func flag(_ name: String) -> Bool { props.child(m, name).map { XlsxParse.flag($0.attribute("val"), true) } ?? false }
        var name = baseFont.name
        if let n = props.child(m, "rFont")?.attribute("val"), !n.isEmpty { name = n }
        var size = baseFont.size
        if let s = XlsxParse.double(props.child(m, "sz")?.attribute("val")), s > 0, s <= 409 { size = s }
        let color = props.child(m, "color").map { readColor($0, theme) } ?? baseFont.color
        return XlsxFont(name: name, size: size, bold: flag("b"), italic: flag("i"), underline: underline(props.child(m, "u")), strike: flag("strike"), color: color)
    }

    private static func readFill(_ f: OfficeXmlElement, _ theme: DocxTheme) -> XlsxFill {
        guard let pattern = f.child(m, "patternFill") else { return XlsxFill(color: nil, unsupported: f.child(m, "gradientFill") != nil) }
        let type = pattern.attribute("patternType") ?? "none"
        if type == "none" { return XlsxFill(color: nil, unsupported: false) }
        if type != "solid" { return XlsxFill(color: nil, unsupported: true) }
        return XlsxFill(color: readColor(pattern.child(m, "fgColor"), theme), unsupported: false)
    }

    private static func readBorder(_ b: OfficeXmlElement, _ theme: DocxTheme) -> XlsxBorder {
        func edge(_ name: String, _ alternative: String) -> XlsxBorderEdge? {
            let e = b.child(m, name) ?? b.child(m, alternative)
            guard let e, let style = e.attribute("style"), style != "none" else { return nil }
            return XlsxBorderEdge(style: style, color: readColor(e.child(m, "color"), theme))
        }
        return XlsxBorder(left: edge("left", "start"), right: edge("right", "end"), top: edge("top", "top"), bottom: edge("bottom", "bottom"))
    }

    private static func readXf(_ x: OfficeXmlElement) -> XlsxXf {
        let a = x.child(m, "alignment")
        let horizontal = a?.attribute("horizontal").flatMap { XlsxHorizontal(rawValue: $0) } ?? .general
        let vertical = a?.attribute("vertical").flatMap { XlsxVertical(rawValue: $0) } ?? .bottom
        return XlsxXf(
            font: XlsxParse.int(x.attribute("fontId")) ?? 0, fill: XlsxParse.int(x.attribute("fillId")) ?? 0,
            border: XlsxParse.int(x.attribute("borderId")) ?? 0, numberFormatId: XlsxParse.int(x.attribute("numFmtId")) ?? 0,
            horizontal: horizontal, vertical: vertical, wrap: XlsxParse.flag(a?.attribute("wrapText"), false),
            indent: min(XlsxParse.int(a?.attribute("indent")) ?? 0, 250), rotated: (XlsxParse.int(a?.attribute("textRotation")) ?? 0) != 0)
    }

    private static func readColor(_ e: OfficeXmlElement?, _ theme: DocxTheme) -> Int? {
        guard let e, !XlsxParse.flag(e.attribute("auto"), false) else { return nil }
        var rgb: Int?
        if let direct = XlsxParse.hex(e.attribute("rgb")) {
            rgb = direct
        } else if let index = XlsxParse.int(e.attribute("indexed")) {
            rgb = index < palette.count ? palette[index] : index == 65 ? 0xFFFFFF : nil
        } else if let t = XlsxParse.int(e.attribute("theme")), t < themeNames.count {
            rgb = theme.color(themeNames[t]) ?? (t == 0 ? 0xFFFFFF : t == 1 ? 0x000000 : nil)
        }
        guard let rgb else { return nil }
        if let tint = XlsxParse.double(e.attribute("tint")), tint != 0 { return Self.tint(rgb, max(-1, min(1, tint))) }
        return rgb
    }

    /// Lightens or darkens a colour the way the file format defines tint: luminance in HLS space.
    private static func tint(_ rgb: Int, _ tint: Double) -> Int {
        var r = Double(rgb >> 16 & 0xFF) / 255.0, g = Double(rgb >> 8 & 0xFF) / 255.0, b = Double(rgb & 0xFF) / 255.0
        let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
        var l = (maxC + minC) / 2, h = 0.0, s = 0.0
        if maxC != minC {
            let d = maxC - minC
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            if maxC == r {
                h = ((g - b) / d + (g < b ? 6 : 0)) / 6
            } else if maxC == g {
                h = ((b - r) / d + 2) / 6
            } else {
                h = ((r - g) / d + 4) / 6
            }
        }
        l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint
        if s == 0 {
            r = l
            g = l
            b = l
        } else {
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
            r = hue(p, q, h + 1.0 / 3)
            g = hue(p, q, h)
            b = hue(p, q, h - 1.0 / 3)
        }
        func byte(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255 + 0.5).rounded(.down)) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    private static func hue(_ p: Double, _ q: Double, _ tIn: Double) -> Double {
        var t = tIn
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 0.5 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
}

/// Reads the numbers and flags that attributes carry, the same way in both engines: no signs, spaces or locale.
enum XlsxParse {
    static func int(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let units = Array(text.utf16)
        if units.count > 9 || units.contains(where: { $0 < 0x30 || $0 > 0x39 }) { return nil }
        return Int(String(decoding: units, as: UTF16.self))
    }

    static func double(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        let units = Array(text.utf16)
        if units.count > 40 { return nil }
        for c in units where !((c >= 0x30 && c <= 0x39) || c == 0x2B || c == 0x2D || c == 0x2E || c == 0x65 || c == 0x45) { return nil }
        guard let v = Double(String(decoding: units, as: UTF16.self)), v.isFinite else { return nil }
        return v
    }

    static func flag(_ text: String?, _ whenMissing: Bool) -> Bool {
        guard let text else { return whenMissing }
        return Array(text.utf16) == [0x31] || Array(text.utf16) == Array("true".utf16)
    }

    /// The 0xRRGGBB of an AARRGGBB or RRGGBB attribute.
    static func hex(_ text: String?) -> Int? {
        guard let text else { return nil }
        let units = Array(text.utf16)
        guard units.count == 6 || units.count == 8 else { return nil }
        for c in units where !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)) { return nil }
        return Int(String(decoding: units.suffix(6), as: UTF16.self), radix: 16)
    }
}
