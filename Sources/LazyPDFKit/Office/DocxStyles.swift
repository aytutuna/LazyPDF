import Foundation

// Twin of windows/LazyPDF.Core/Office/Docx/DocxStyles.cs.

/// Run formatting as a document states it; nil is "not said", so a later layer can fill it in.
struct RunProps {
    var family: String?
    /// Points.
    var size: Double?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var caps: Bool?
    var hidden: Bool?
    /// The complex-script (Arabic, Hebrew) counterparts: font, size, bold and italic, which apply to the characters of those scripts.
    var csFamily: String?
    var csSize: Double?
    var csBold: Bool?
    var csItalic: Bool?
    /// w:rtl: the run is right to left. w:cs: the run is formatted as complex script whatever its characters.
    var rtl: Bool?
    var complex: Bool?
    var color: Int?
    /// 0xRRGGBB, or -1 for none.
    var highlight: Int?
    /// 1 superscript, -1 subscript, 0 baseline.
    var vertical: Int?

    mutating func apply(_ rPr: OfficeXmlElement?, _ theme: DocxTheme) {
        guard let rPr else { return }
        let w = DocxReader.w
        for e in rPr.elements {
            if e.uri != w { continue }
            let val = e.attribute(w, "val")
            switch e.name {
            case "rFonts":
                let themed = e.attribute(w, "asciiTheme") ?? e.attribute(w, "hAnsiTheme")
                let named = e.attribute(w, "ascii") ?? e.attribute(w, "hAnsi")
                if let themed, let themeFont = theme.font(themed) {
                    family = themeFont
                } else if let named, !named.isEmpty {
                    family = named
                }
                let csThemed = e.attribute(w, "cstheme")
                let csNamed = e.attribute(w, "cs")
                if let csThemed, let csThemeFont = theme.complexFont(csThemed) {
                    csFamily = csThemeFont
                } else if let csNamed, !csNamed.isEmpty {
                    csFamily = csNamed
                }
            case "b": bold = DocxReader.on(e)
            case "i": italic = DocxReader.on(e)
            case "bCs": csBold = DocxReader.on(e)
            case "iCs": csItalic = DocxReader.on(e)
            case "rtl": rtl = DocxReader.on(e)
            case "cs": complex = DocxReader.on(e)
            case "u": underline = val != "none"
            case "strike", "dstrike": strike = DocxReader.on(e)
            case "caps": caps = DocxReader.on(e)
            case "vanish": hidden = DocxReader.on(e)
            case "color":
                var found = DocxReader.hex(val)
                if found == nil {
                    if let tc = e.attribute(w, "themeColor") {
                        found = theme.color(tc)
                    } else if val == "auto" {
                        found = 0
                    }
                }
                if let found { color = found }
            case "sz":
                if let half = DocxReader.number(val), half > 0 { size = half / 2 }
            case "szCs":
                if let csHalf = DocxReader.number(val), csHalf > 0 { csSize = csHalf / 2 }
            case "highlight":
                if let val {
                    highlight = val == "none" ? -1 : (DocxReader.highlightColor(val) ?? highlight)
                }
            case "vertAlign":
                switch val {
                case "superscript": vertical = 1
                case "subscript": vertical = -1
                case "baseline": vertical = 0
                default: break
                }
            default: break
            }
        }
    }
}

/// Paragraph formatting as a document states it; lengths in points.
struct ParaProps {
    var align: LayoutAlign?
    var left: Double?
    var right: Double?
    var first: Double?
    var before: Double?
    var after: Double?
    var line: Double?
    var lineRule: String?
    var keepNext: Bool?
    var pageBreakBefore: Bool?
    var widow: Bool?
    var bidi: Bool?
    var numId: Int?
    var ilvl: Int?

    mutating func apply(_ pPr: OfficeXmlElement?) {
        guard let pPr else { return }
        let w = DocxReader.w
        for e in pPr.elements {
            if e.uri != w { continue }
            switch e.name {
            case "jc":
                switch e.attribute(w, "val") {
                case "left", "start": align = .left
                case "center": align = .center
                case "right", "end": align = .right
                case "both", "distribute", "thaiDistribute", "lowKashida", "mediumKashida", "highKashida": align = .justify
                default: break
                }
            case "ind":
                left = Self.length(e, "left", "start") ?? left
                right = Self.length(e, "right", "end") ?? right
                if let hanging = Self.length(e, "hanging") {
                    first = -hanging
                } else if let firstLine = Self.length(e, "firstLine") {
                    first = firstLine
                }
            case "spacing":
                before = Self.length(e, "before") ?? before
                after = Self.length(e, "after") ?? after
                if let l = DocxReader.number(e.attribute(w, "line")) { line = l }
                lineRule = e.attribute(w, "lineRule") ?? lineRule
            case "bidi": bidi = DocxReader.on(e)
            case "keepNext": keepNext = DocxReader.on(e)
            case "pageBreakBefore": pageBreakBefore = DocxReader.on(e)
            case "widowControl": widow = DocxReader.on(e)
            case "numPr":
                if let id = DocxReader.number(e.child(w, "numId")?.attribute(w, "val")) {
                    numId = Int(min(max(id, -2147483648), 2147483647))
                }
                if let level = DocxReader.number(e.child(w, "ilvl")?.attribute(w, "val")) {
                    ilvl = Int(min(max(level, -2147483648), 2147483647))
                }
            default: break
            }
        }
    }

    // Twips to points, kept inside what Word itself allows.
    private static func length(_ e: OfficeXmlElement, _ name: String, _ alias: String? = nil) -> Double? {
        let w = DocxReader.w
        let text = e.attribute(w, name) ?? alias.flatMap { e.attribute(w, $0) }
        guard let v = DocxReader.number(text) else { return nil }
        return min(max(v / 20, -1584), 1584)
    }
}

final class DocxTheme {
    private static let colorNames: [String: String] = [
        "text1": "dk1", "dark1": "dk1", "background1": "lt1", "light1": "lt1",
        "text2": "dk2", "dark2": "dk2", "background2": "lt2", "light2": "lt2",
        "hyperlink": "hlink", "followedHyperlink": "folHlink",
    ]

    private var major: String?
    private var minor: String?
    private var majorCs: String?
    private var minorCs: String?
    private var colors: [String: Int] = [:]

    static func read(_ root: OfficeXmlElement?) -> DocxTheme {
        let theme = DocxTheme()
        let a = DocxReader.a
        let elements = root?.child(a, "themeElements")
        let fonts = elements?.child(a, "fontScheme")
        theme.major = typeface(fonts?.child(a, "majorFont"))
        theme.minor = typeface(fonts?.child(a, "minorFont"))
        theme.majorCs = typeface(fonts?.child(a, "majorFont"), "cs")
        theme.minorCs = typeface(fonts?.child(a, "minorFont"), "cs")
        for c in elements?.child(a, "clrScheme")?.elements ?? [] {
            let hex = c.child(a, "srgbClr")?.attribute("val") ?? c.child(a, "sysClr")?.attribute("lastClr")
            if let rgb = DocxReader.hex(hex) { theme.colors[c.name] = rgb }
        }
        return theme
    }

    private static func typeface(_ scheme: OfficeXmlElement?, _ script: String = "latin") -> String? {
        guard let name = scheme?.child(DocxReader.a, script)?.attribute("typeface"), !name.isEmpty else { return nil }
        return name
    }

    /// The latin font of a theme reference such as minorHAnsi or majorAscii.
    func font(_ reference: String) -> String? {
        if reference.utf8.starts(with: "major".utf8) { return major }
        if reference.utf8.starts(with: "minor".utf8) { return minor }
        return nil
    }

    /// The complex-script font of a theme reference such as minorBidi or majorBidi; nil when the theme names none.
    func complexFont(_ reference: String) -> String? {
        if reference.utf8.starts(with: "major".utf8) { return majorCs }
        if reference.utf8.starts(with: "minor".utf8) { return minorCs }
        return nil
    }

    func color(_ name: String) -> Int? { colors[Self.colorNames[name] ?? name] }
}

struct DocxStyle {
    let id: String
    let type: String
    let basedOn: String?
    let pPr: OfficeXmlElement?
    let rPr: OfficeXmlElement?
    let source: OfficeXmlElement
}

final class DocxStyles {
    private static let maxChain = 50

    private var styles: [String: DocxStyle] = [:]
    private var defaultPPr: OfficeXmlElement?
    private var defaultRPr: OfficeXmlElement?

    private(set) var defaultParagraph: String?
    private(set) var defaultCharacter: String?
    private(set) var defaultTable: String?

    static func read(_ root: OfficeXmlElement?) -> DocxStyles {
        let styles = DocxStyles()
        guard let root else { return styles }
        let w = DocxReader.w
        let defaults = root.child(w, "docDefaults")
        styles.defaultPPr = defaults?.child(w, "pPrDefault")?.child(w, "pPr")
        styles.defaultRPr = defaults?.child(w, "rPrDefault")?.child(w, "rPr")
        for e in root.elements(w, "style") {
            guard let id = e.attribute(w, "styleId"), styles.styles[id] == nil else { continue }
            let type = e.attribute(w, "type") ?? "paragraph"
            let basedOn = e.child(w, "basedOn")?.attribute(w, "val")
            styles.styles[id] = DocxStyle(id: id, type: type, basedOn: basedOn, pPr: e.child(w, "pPr"), rPr: e.child(w, "rPr"), source: e)
            if let flag = e.attribute(w, "default"), flag == "1" || flag == "true" || flag == "on" {
                if type == "paragraph" && styles.defaultParagraph == nil { styles.defaultParagraph = id }
                if type == "character" && styles.defaultCharacter == nil { styles.defaultCharacter = id }
                if type == "table" && styles.defaultTable == nil { styles.defaultTable = id }
            }
        }
        return styles
    }

    private func find(_ id: String?, _ type: String) -> DocxStyle? {
        guard let id, let s = styles[id], s.type == type else { return nil }
        return s
    }

    /// The document defaults, then the table style layers when the paragraph is in a table, then the paragraph style and
    /// the styles it is based on, farthest first.
    func paragraph(_ id: String?, _ theme: DocxTheme, _ tableLayers: [OfficeXmlElement] = []) -> (ParaProps, RunProps) {
        var paragraph = ParaProps()
        var run = RunProps()
        run.apply(defaultRPr, theme)
        paragraph.apply(defaultPPr)
        for layer in tableLayers {
            paragraph.apply(layer.child(DocxReader.w, "pPr"))
            run.apply(layer.child(DocxReader.w, "rPr"), theme)
        }
        for s in chain(find(id, "paragraph") == nil ? defaultParagraph : id, "paragraph") {
            paragraph.apply(s.pPr)
            run.apply(s.rPr, theme)
        }
        return (paragraph, run)
    }

    /// Puts a character style (or the default one) on top of the run properties already known.
    func character(_ id: String?, _ run: inout RunProps, _ theme: DocxTheme) {
        for s in chain(find(id, "character") == nil ? defaultCharacter : id, "character") { run.apply(s.rPr, theme) }
    }

    /// The table style (or the default one) and the styles it is based on, farthest first.
    func table(_ id: String?) -> [DocxStyle] { chain(find(id, "table") == nil ? defaultTable : id, "table") }

    private func chain(_ id: String?, _ type: String) -> [DocxStyle] {
        var chain: [DocxStyle] = []
        var s = find(id, type)
        while let current = s, chain.count < Self.maxChain, !chain.contains(where: { $0.id == current.id }) {
            chain.append(current)
            s = find(current.basedOn, type)
        }
        return chain.reversed()
    }
}
