import Foundation

// Twin of windows/LazyPDF.Core/Office/Pptx/PptxStyle.cs: the layers of text formatting a slide shape inherits.

/// A spacing as the file states it: a percentage of the line (1 is 100 percent) or points.
struct PptxSpacing {
    let value: Double
    let points: Bool
}

/// Run formatting as one layer states it; nil is "not said".
struct PptxRunProps {
    var family: String?
    var size: Double?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var caps: Bool?
    var link: Bool?
    var color: Int?
    var highlight: Int?
    /// Percent of the size; positive is superscript.
    var baseline: Double?

    mutating func apply(_ rPr: OfficeXmlElement?, _ colors: PptxColors) {
        guard let rPr else { return }
        let a = DocxReader.a
        if let size = DocxReader.number(rPr.attribute("sz")), size > 0 { self.size = PptxColors.clamp(size / 100, 1, 1000) }
        bold = Self.flag(rPr.attribute("b")) ?? bold
        italic = Self.flag(rPr.attribute("i")) ?? italic
        if let u = rPr.attribute("u") { underline = u != "none" }
        if let s = rPr.attribute("strike") { strike = s != "noStrike" }
        if let c = rPr.attribute("cap") { caps = c == "all" }
        if let b = DocxReader.number(rPr.attribute("baseline")) { baseline = PptxColors.clamp(b / 1000, -100, 100) }
        for e in rPr.elements where e.uri == a {
            switch e.name {
            case "solidFill": color = colors.first(e) ?? color
            case "gradFill": color = colors.first(e.child(a, "gsLst")?.child(a, "gs")) ?? color
            case "highlight": highlight = colors.first(e) ?? highlight
            case "latin": family = PptxStyle.font(e.attribute("typeface"), colors) ?? family
            case "hlinkClick": link = true
            default: break
            }
        }
    }

    static func flag(_ value: String?) -> Bool? {
        switch value {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }
}

/// Formatting of one outline level as the layers state it, laid over each other with `apply`.
struct PptxLevelProps {
    var align: LayoutAlign?
    var marL: Double?
    var indent: Double?
    var line: PptxSpacing?
    var before: PptxSpacing?
    var after: PptxSpacing?
    /// none, char or auto.
    var bulletKind: String?
    var bulletChar: String?
    var bulletFont: String?
    var autoType: String?
    var autoStart: Int?
    var bulletColor: Int?
    var bulletPercent: Double?
    var bulletPoints: Double?
    var run = PptxRunProps()

    mutating func apply(_ pPr: OfficeXmlElement?, _ colors: PptxColors) {
        guard let pPr else { return }
        let a = DocxReader.a
        if let left = DocxReader.number(pPr.attribute("marL")) { marL = Self.emu(left) }
        if let first = DocxReader.number(pPr.attribute("indent")) { indent = Self.emu(first) }
        switch pPr.attribute("algn") {
        case "l": align = .left
        case "ctr": align = .center
        case "r": align = .right
        case "just", "justLow", "dist", "thaiDist": align = .justify
        default: break
        }
        for e in pPr.elements where e.uri == a {
            switch e.name {
            case "lnSpc": line = Self.spacing(e) ?? line
            case "spcBef": before = Self.spacing(e) ?? before
            case "spcAft": after = Self.spacing(e) ?? after
            case "buNone": bulletKind = "none"
            case "buChar":
                if let c = e.attribute("char"), !c.utf16.isEmpty {
                    bulletKind = "char"
                    bulletChar = c
                }
            case "buAutoNum":
                bulletKind = "auto"
                autoType = e.attribute("type") ?? "arabicPeriod"
                autoStart = DocxReader.number(e.attribute("startAt")).map { Int(PptxColors.clamp($0, 1, 32767)) } ?? 1
            case "buFont": bulletFont = PptxStyle.font(e.attribute("typeface"), colors)
            case "buFontTx": bulletFont = nil
            case "buClr": bulletColor = colors.first(e)
            case "buClrTx": bulletColor = nil
            case "buSzPct":
                bulletPercent = PptxColors.clamp((DocxReader.number(e.attribute("val")) ?? 100_000) / 100_000, 0.25, 4)
                bulletPoints = nil
            case "buSzPts":
                bulletPoints = PptxColors.clamp((DocxReader.number(e.attribute("val")) ?? 1000) / 100, 1, 1000)
                bulletPercent = nil
            case "buSzTx":
                bulletPercent = nil
                bulletPoints = nil
            case "defRPr": run.apply(e, colors)
            default: break
            }
        }
    }

    private static func emu(_ v: Double) -> Double { PptxColors.clamp(v / 12700, -PptxLimits.maxSide, PptxLimits.maxSide) }

    private static func spacing(_ e: OfficeXmlElement) -> PptxSpacing? {
        let a = DocxReader.a
        if let percent = e.child(a, "spcPct"), let p = DocxReader.number(percent.attribute("val")) {
            return PptxSpacing(value: PptxColors.clamp(p / 100_000, 0, 132), points: false)
        }
        if let points = e.child(a, "spcPts"), let pt = DocxReader.number(points.attribute("val")) {
            return PptxSpacing(value: PptxColors.clamp(pt / 100, 0, 1584), points: true)
        }
        return nil
    }
}

/// The body properties of a shape as the layers state them, and the autofit that was stored.
struct PptxBodyProps {
    var left: Double?
    var top: Double?
    var right: Double?
    var bottom: Double?
    var anchor: LayoutVAlign?
    var wrap: Bool?
    var rotated = false
    var fontScale = 1.0
    var lineReduction = 0.0

    mutating func apply(_ bodyPr: OfficeXmlElement?) {
        guard let bodyPr else { return }
        left = Self.inset(bodyPr, "lIns") ?? left
        top = Self.inset(bodyPr, "tIns") ?? top
        right = Self.inset(bodyPr, "rIns") ?? right
        bottom = Self.inset(bodyPr, "bIns") ?? bottom
        switch bodyPr.attribute("anchor") {
        case "t", "just", "dist": anchor = .top
        case "ctr": anchor = .center
        case "b": anchor = .bottom
        default: break
        }
        switch bodyPr.attribute("wrap") {
        case "none": wrap = false
        case "square": wrap = true
        default: break
        }
        if let vert = bodyPr.attribute("vert") { rotated = vert != "horz" }
        if let rot = DocxReader.number(bodyPr.attribute("rot")), rot != 0 { rotated = true }
        for e in bodyPr.elements where e.uri == DocxReader.a {
            if e.name == "normAutofit" {
                fontScale = PptxColors.clamp((DocxReader.number(e.attribute("fontScale")) ?? 100_000) / 100_000, 0.1, 1)
                lineReduction = PptxColors.clamp((DocxReader.number(e.attribute("lnSpcReduction")) ?? 0) / 100_000, 0, 0.9)
            } else if e.name == "noAutofit" || e.name == "spAutoFit" {
                fontScale = 1
                lineReduction = 0
            }
        }
    }

    private static func inset(_ e: OfficeXmlElement, _ name: String) -> Double? {
        DocxReader.number(e.attribute(name)).map { PptxColors.clamp($0 / 12700, 0, PptxLimits.maxSide) }
    }
}

enum PptxStyle {
    /// A typeface name; +mj-lt and +mn-lt are the theme's heading and body fonts, other theme references name nothing.
    static func font(_ typeface: String?, _ colors: PptxColors) -> String? {
        guard let typeface, let first = typeface.utf16.first else { return nil }
        if first != 0x2B { return typeface }
        switch typeface {
        case "+mj-lt": return colors.theme.font("major")
        case "+mn-lt": return colors.theme.font("minor")
        default: return nil
        }
    }
}
