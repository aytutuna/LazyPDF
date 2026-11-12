import Foundation

// Twin of windows/LazyPDF.Core/Office/Pptx/PptxColors.cs: turns DrawingML color elements into 0xRRGGBB against a theme and the
// color map of the master, with the transforms in the order they are written. Alpha is ignored.

struct PptxColors {
    private static let gamma = 2.2

    private static let named: [String: Int] = [
        "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "yellow": 0xFFFF00,
        "gray": 0x808080, "grey": 0x808080, "silver": 0xC0C0C0, "maroon": 0x800000, "purple": 0x800080, "orange": 0xFFA500,
        "lime": 0x00FF00, "aqua": 0x00FFFF, "cyan": 0x00FFFF, "fuchsia": 0xFF00FF, "magenta": 0xFF00FF, "navy": 0x000080,
        "teal": 0x008080, "olive": 0x808000, "darkBlue": 0x00008B, "darkRed": 0x8B0000, "darkGreen": 0x006400,
        "darkGray": 0xA9A9A9, "darkGrey": 0xA9A9A9, "lightGray": 0xD3D3D3, "lightGrey": 0xD3D3D3, "dkGray": 0xA9A9A9, "ltGray": 0xD3D3D3,
        "pink": 0xFFC0CB, "brown": 0xA52A2A, "gold": 0xFFD700,
    ]

    /// The identity mapping of a master that has no color map.
    static let defaultMap: [String: String] = [
        "bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2",
        "accent1": "accent1", "accent2": "accent2", "accent3": "accent3", "accent4": "accent4", "accent5": "accent5", "accent6": "accent6",
        "hlink": "hlink", "folHlink": "folHlink",
    ]

    let theme: DocxTheme
    private let map: [String: String]

    init(_ theme: DocxTheme, _ map: [String: String]) {
        self.theme = theme
        self.map = map
    }

    var hyperlink: Int? { scheme("hlink") }

    /// The color map written as attributes (bg1="lt1" ...) of clrMap or overrideClrMapping.
    static func readMap(_ e: OfficeXmlElement?) -> [String: String] {
        var result = defaultMap
        guard let e else { return result }
        for name in defaultMap.keys {
            if let value = e.attribute(name) { result[name] = value }
        }
        return result
    }

    func withMap(_ other: [String: String]) -> PptxColors { PptxColors(theme, other) }

    /// The first color element inside `parent` (the color of a fill, line or font reference).
    func first(_ parent: OfficeXmlElement?, _ placeholder: Int? = nil) -> Int? {
        for e in parent?.elements ?? [] where e.uri == DocxReader.a {
            if let color = resolve(e, placeholder) { return color }
        }
        return nil
    }

    func resolve(_ e: OfficeXmlElement, _ placeholder: Int?) -> Int? {
        var rgb: [Double]?
        switch e.name {
        case "srgbClr": rgb = Self.unpack(DocxReader.hex(e.attribute("val")))
        case "schemeClr": rgb = Self.unpack(e.attribute("val") == "phClr" ? placeholder : scheme(e.attribute("val")))
        case "sysClr":
            let val = e.attribute("val")
            rgb = Self.unpack(DocxReader.hex(e.attribute("lastClr")) ?? (val == "window" ? 0xFFFFFF : val == "windowText" ? 0 : nil))
        case "prstClr":
            rgb = Self.unpack(e.attribute("val").flatMap { Self.named[$0] })
        case "scrgbClr": rgb = [Self.linear(e, "r"), Self.linear(e, "g"), Self.linear(e, "b")]
        case "hslClr":
            let hue = ((DocxReader.number(e.attribute("hue")) ?? 0) / 60000).truncatingRemainder(dividingBy: 360)
            rgb = Self.fromHsl(hue, Self.clamp(Self.percent(e.attribute("sat")), 0, 1), Self.clamp(Self.percent(e.attribute("lum")), 0, 1))
        default: rgb = nil
        }
        guard var c = rgb else { return nil }
        for t in e.elements where t.uri == DocxReader.a {
            Self.transform(&c, t.name, Self.percent(t.attribute("val")), DocxReader.number(t.attribute("val")) ?? 0)
        }
        return Self.pack(c)
    }

    private func scheme(_ name: String?) -> Int? {
        guard let name else { return nil }
        return theme.color(map[name] ?? name)
    }

    static func clamp(_ v: Double, _ low: Double, _ high: Double) -> Double { min(max(v, low), high) }

    private static func percent(_ value: String?) -> Double { clamp((DocxReader.number(value) ?? 0) / 100_000, -100, 100) }

    private static func linear(_ e: OfficeXmlElement, _ name: String) -> Double { clamp(percent(e.attribute(name)), 0, 1) }

    private static func unpack(_ rgb: Int?) -> [Double]? {
        guard let c = rgb else { return nil }
        return [Double(c >> 16 & 0xFF) / 255.0, Double(c >> 8 & 0xFF) / 255.0, Double(c & 0xFF) / 255.0]
    }

    private static func pack(_ rgb: [Double]) -> Int {
        func channel(_ v: Double) -> Int { Int((clamp(v, 0, 1) * 255).rounded(.toNearestOrAwayFromZero)) }
        return channel(rgb[0]) << 16 | channel(rgb[1]) << 8 | channel(rgb[2])
    }

    private static func transform(_ rgb: inout [Double], _ name: String, _ fraction: Double, _ raw: Double) {
        switch name {
        case "lumMod", "lumOff", "lum", "satMod", "satOff", "sat", "hueMod", "hueOff", "hue":
            var (h, s, l) = toHsl(rgb)
            switch name {
            case "lumMod": l *= fraction
            case "lumOff": l += fraction
            case "lum": l = fraction
            case "satMod": s *= fraction
            case "satOff": s += fraction
            case "sat": s = fraction
            case "hueMod": h *= fraction
            case "hueOff": h += raw / 60000
            default: h = raw / 60000
            }
            rgb = fromHsl(h - (h / 360).rounded(.down) * 360, clamp(s, 0, 1), clamp(l, 0, 1))
        case "tint":
            for i in 0..<3 { rgb[i] = pow(1 - (1 - pow(rgb[i], gamma)) * clamp(fraction, 0, 1), 1 / gamma) }
        case "shade":
            for i in 0..<3 { rgb[i] = pow(pow(rgb[i], gamma) * clamp(fraction, 0, 1), 1 / gamma) }
        case "comp":
            let (h, s, l) = toHsl(rgb)
            rgb = fromHsl((h + 180).truncatingRemainder(dividingBy: 360), s, l)
        case "inv":
            rgb = [1 - rgb[0], 1 - rgb[1], 1 - rgb[2]]
        case "gray":
            let y = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]
            rgb = [y, y, y]
        default: break
        }
    }

    // Hue in degrees, saturation and lightness 0 to 1.
    private static func toHsl(_ c: [Double]) -> (Double, Double, Double) {
        let hi = max(c[0], max(c[1], c[2])), lo = min(c[0], min(c[1], c[2]))
        let l = (hi + lo) / 2, d = hi - lo
        if d == 0 { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - hi - lo) : d / (hi + lo)
        let h = hi == c[0] ? (c[1] - c[2]) / d + (c[1] < c[2] ? 6 : 0) : hi == c[1] ? (c[2] - c[0]) / d + 2 : (c[0] - c[1]) / d + 4
        return (h * 60, s, l)
    }

    private static func fromHsl(_ h: Double, _ s: Double, _ l: Double) -> [Double] {
        if s == 0 { return [l, l, l] }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func part(_ value: Double) -> Double {
            let t = value - value.rounded(.down)
            return t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p
        }
        return [part(h / 360 + 1.0 / 3), part(h / 360), part(h / 360 - 1.0 / 3)]
    }
}
