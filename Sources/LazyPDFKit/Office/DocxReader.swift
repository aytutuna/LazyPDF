import Foundation

// Twin of windows/LazyPDF.Core/Office/Docx/DocxReader.cs: reads a .docx package into the layout model. What it does not
// carry over is counted in `LayoutDocument.skipped`.

final class DocxReader {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    private static let mathNs = "http://schemas.openxmlformats.org/officeDocument/2006/math"
    private static let stylesType = r + "/styles"
    private static let themeType = r + "/theme"
    private static let headerType = r + "/header"
    private static let footerType = r + "/footer"

    private static let highlights: [String: Int] = [
        "black": 0x000000, "blue": 0x0000FF, "cyan": 0x00FFFF, "green": 0x00FF00, "magenta": 0xFF00FF, "red": 0xFF0000,
        "yellow": 0xFFFF00, "white": 0xFFFFFF, "darkBlue": 0x000080, "darkCyan": 0x008080, "darkGreen": 0x008000,
        "darkMagenta": 0x800080, "darkRed": 0x800000, "darkYellow": 0x808000, "darkGray": 0x808080, "lightGray": 0xC0C0C0,
    ]

    private final class Field {
        var code = ""
        var inResult = false
        var classified = false
        var outer = false
        var kind = LayoutField.none
        var format = RunProps()
    }

    private final class Piece {
        let format: LayoutRun
        var text = ""

        init(_ format: LayoutRun) { self.format = format }
    }

    private let package: OpcPackage
    private var skipped: [String: Int] = [:]
    private var paragraphStyles: [String: (ParaProps, RunProps)] = [:]
    private var bands: [String: [LayoutParagraph]] = [:]
    private var styles = DocxStyles()
    private var theme = DocxTheme()

    // State of the part being read.
    private var blocks: [LayoutBlock] = []
    private var sectionEnds: [(at: Int, properties: OfficeXmlElement)] = []
    private var fields: [Field] = []
    private var pieces: [Piece] = []
    private var inBand = false
    private var breaker: (() -> Void)?

    private init(_ package: OpcPackage) { self.package = package }

    static func read(_ data: [UInt8]) throws -> LayoutDocument {
        if data.count >= 4 && data[0] == 0xD0 && data[1] == 0xCF && data[2] == 0x11 && data[3] == 0xE0 {
            throw PdfReadException(.unsupported, "This is a Word 97-2003 file. Save it as .docx first.")
        }
        return try DocxReader(try OpcPackage.open(data)).run()
    }

    private func run() throws -> LayoutDocument {
        let w = Self.w
        guard let main = try package.relationships("").first(where: { $0.type == OpcPackage.officeDocument })?.target else {
            throw PdfReadException.damaged("The file has no main document part.")
        }
        if !package.contains(main) { throw PdfReadException.damaged("The package has no part \(main).") }
        guard let type = package.contentType(main), contains(type, "wordprocessingml") else {
            throw PdfReadException(.unsupported, "The file is not a Word document.")
        }
        let root = try package.xml(main)
        let body = root.uri == w && root.name == "document" ? root.child(w, "body") : nil
        guard let body else { throw PdfReadException(.unsupported, "The document is not in the Word 2007 format.") }

        let relationships = try package.relationships(main)
        styles = DocxStyles.read(try part(relationships, Self.stylesType))
        theme = DocxTheme.read(try part(relationships, Self.themeType))

        try readBlocks(body)
        let all = blocks
        var ends = sectionEnds
        ends.append((all.count, body.child(w, "sectPr") ?? OfficeXmlElement(uri: w, name: "sectPr", attributes: [])))

        let document = LayoutDocument()
        var from = 0
        var previous: LayoutSection?
        for (index, end) in ends.enumerated() {
            let slice = Array(all[from..<end.at])
            from = end.at
            let properties = end.properties
            let geometry = Self.geometry(properties)
            let continuous = properties.child(w, "type")?.attribute(w, "val") == "continuous"
            if continuous, let previous, Self.same(previous.page, geometry) {
                previous.blocks.append(contentsOf: slice)
                continue
            }
            // A section made only of the tail after the last section break has nothing to show.
            if slice.isEmpty && previous != nil && index == ends.count - 1 { continue }
            let section = LayoutSection()
            section.page = geometry
            section.header = try band(properties, relationships, Self.headerType, "headerReference", previous?.header)
            section.footer = try band(properties, relationships, Self.footerType, "footerReference", previous?.footer)
            section.blocks = slice
            if let title = properties.child(w, "titlePg"), Self.on(title),
               (properties.elements(w, "headerReference") + properties.elements(w, "footerReference")).contains(where: { $0.attribute(w, "type") == "first" }) {
                skip("header-variant")
            }
            document.sections.append(section)
            previous = section
        }
        if document.sections.isEmpty {
            let section = LayoutSection()
            section.blocks = all
            document.sections.append(section)
        }
        for kind in skipped.keys.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }) {
            document.skipped.append(SkippedFeature(kind, skipped[kind]!))
        }
        return document
    }

    private func contains(_ text: String, _ part: String) -> Bool {
        let t = Array(text.utf8), p = Array(part.utf8)
        if p.isEmpty { return true }
        if t.count < p.count { return false }
        for i in 0...(t.count - p.count) where Array(t[i..<(i + p.count)]) == p { return true }
        return false
    }

    private func part(_ relationships: [OpcRelationship], _ type: String) throws -> OfficeXmlElement? {
        guard let target = relationships.first(where: { $0.type == type })?.target, package.contains(target) else { return nil }
        return try package.xml(target)
    }

    private func skip(_ kind: String) { skipped[kind, default: 0] += 1 }

    private static func same(_ a: LayoutGeometry, _ b: LayoutGeometry) -> Bool {
        a.width == b.width && a.height == b.height && a.top == b.top && a.right == b.right && a.bottom == b.bottom && a.left == b.left
            && a.headerDistance == b.headerDistance && a.footerDistance == b.footerDistance
    }

    private static func geometry(_ sectPr: OfficeXmlElement) -> LayoutGeometry {
        let size = sectPr.child(w, "pgSz")
        var width = points(size, "w") ?? 612, height = points(size, "h") ?? 792
        if size?.attribute(w, "orient") == "landscape" && width < height { swap(&width, &height) }
        let margin = sectPr.child(w, "pgMar")
        return LayoutGeometry(
            width: width,
            height: height,
            top: abs(points(margin, "top") ?? 72),
            right: points(margin, "right") ?? 72,
            bottom: abs(points(margin, "bottom") ?? 72),
            left: (points(margin, "left") ?? 72) + (points(margin, "gutter") ?? 0),
            headerDistance: points(margin, "header") ?? 36,
            footerDistance: points(margin, "footer") ?? 36)
    }

    private static func points(_ e: OfficeXmlElement?, _ name: String) -> Double? {
        number(e?.attribute(w, name)).map { $0 / 20 }
    }

    // A section without its own header or footer shows the previous section's, as in Word.
    private func band(_ sectPr: OfficeXmlElement, _ relationships: [OpcRelationship], _ type: String, _ reference: String,
                      _ inherited: [LayoutParagraph]?) throws -> [LayoutParagraph] {
        let w = Self.w
        let id = sectPr.elements(w, reference).first(where: { ($0.attribute(w, "type") ?? "default") == "default" })?.attribute(Self.r, "id")
        let target = id.flatMap { id in relationships.first(where: { $0.id == id && $0.type == type })?.target }
        guard let target, package.contains(target) else { return inherited ?? [] }
        let key = ZipReader.key(target)
        if let known = bands[key] { return known }

        blocks = []
        fields.removeAll()
        inBand = true
        try readBlocks(try package.xml(target))
        inBand = false
        let made = blocks.compactMap { $0 as? LayoutParagraph }
        bands[key] = made
        return made
    }

    // ---- block level ----

    private func readBlocks(_ container: OfficeXmlElement) throws {
        let w = Self.w
        for e in container.elements {
            try Task.checkCancellation()
            if e.uri == Self.mc && e.name == "AlternateContent" {
                if let picked = Self.pick(e) { try readBlocks(picked) }
                continue
            }
            if e.uri != w { continue }
            switch e.name {
            case "p": try paragraph(e)
            case "tbl":
                // Tables are read as their paragraphs in order until table layout exists.
                skip("table")
                for row in e.elements(w, "tr") {
                    for cell in row.elements(w, "tc") { try readBlocks(cell) }
                }
            case "sdt":
                if let content = e.child(w, "sdtContent") { try readBlocks(content) }
            case "ins", "moveTo":
                skip("tracked-change")
                try readBlocks(e)
            case "del", "moveFrom":
                skip("tracked-change")
            case "customXml":
                try readBlocks(e)
            default: break
            }
        }
    }

    private static func pick(_ alternate: OfficeXmlElement) -> OfficeXmlElement? {
        alternate.elements(mc, "Choice").first ?? alternate.elements(mc, "Fallback").first
    }

    private func paragraph(_ p: OfficeXmlElement) throws {
        let w = Self.w
        let pPr = p.child(w, "pPr")
        let styleId = pPr?.child(w, "pStyle")?.attribute(w, "val")
        let known: (ParaProps, RunProps)
        if let cached = paragraphStyles[styleId ?? ""] {
            known = cached
        } else {
            known = styles.paragraph(styleId, theme)
            paragraphStyles[styleId ?? ""] = known
        }
        var props = known.0
        props.apply(pPr)
        var mark = known.1
        mark.apply(pPr?.child(w, "rPr"), theme)
        if let id = props.numId, id != 0 { skip("numbering") }

        pieces.removeAll()
        var first = true
        func emit(_ last: Bool) {
            guard let runs = self.runs(mark, last) else { return }
            blocks.append(Self.make(props, runs, first && props.pageBreakBefore == true))
            first = false
        }
        breaker = {
            emit(false)
            first = false
            self.blocks.append(LayoutPageBreak())
        }
        defer { breaker = nil }
        try inline(p, known.1)
        emit(true)
        if let sectPr = pPr?.child(w, "sectPr"), !inBand { sectionEnds.append((blocks.count, sectPr)) }
    }

    // The runs collected so far, or nil for the part of a paragraph before a page break that has no text.
    private func runs(_ mark: RunProps, _ last: Bool) -> [LayoutRun]? {
        var runs: [LayoutRun] = []
        for piece in pieces {
            if piece.text.isEmpty && piece.format.field == .none { continue }
            runs.append(Self.rebuild(piece.format, piece.text))
        }
        pieces.removeAll()
        if !runs.isEmpty { return runs }
        // Nothing to show: an empty line takes the height of the paragraph mark. A part before a page break is not a line at all.
        return last ? [Self.rebuild(Self.format(mark, .none), "")] : nil
    }

    private static func rebuild(_ f: LayoutRun, _ text: String) -> LayoutRun {
        let run = LayoutRun()
        run.text = text
        run.family = f.family
        run.size = f.size
        run.bold = f.bold
        run.italic = f.italic
        run.underline = f.underline
        run.strike = f.strike
        run.color = f.color
        run.highlight = f.highlight
        run.shift = f.shift
        run.field = f.field
        return run
    }

    private static func make(_ p: ParaProps, _ runs: [LayoutRun], _ pageBreakBefore: Bool) -> LayoutParagraph {
        var rule: LineRule
        switch p.lineRule {
        case "exact": rule = .exact
        case "atLeast": rule = .atLeast
        default: rule = .multiple
        }
        var spacing = 1.0
        if let line = p.line, line > 0 {
            spacing = rule == .multiple ? min(line / 240, 132) : min(max(line / 20, 1), 1584)
        } else {
            rule = .multiple
        }
        let made = LayoutParagraph()
        made.runs = runs
        made.align = p.align ?? .left
        made.left = p.left ?? 0
        made.right = p.right ?? 0
        made.firstLine = p.first ?? 0
        made.before = max(0, p.before ?? 0)
        made.after = max(0, p.after ?? 0)
        made.lineSpacing = spacing
        made.rule = rule
        made.keepWithNext = p.keepNext == true
        made.pageBreakBefore = pageBreakBefore
        made.widowControl = p.widow != false
        return made
    }

    // ---- inline level ----

    private func inline(_ parent: OfficeXmlElement, _ paragraphRun: RunProps) throws {
        let w = Self.w
        for e in parent.elements {
            try Task.checkCancellation()
            if e.uri == Self.mc && e.name == "AlternateContent" {
                if let picked = Self.pick(e) { try inline(picked, paragraphRun) }
                continue
            }
            if e.uri == Self.mathNs {
                if e.name == "oMath" || e.name == "oMathPara" { skip("equation") }
                continue
            }
            if e.uri != w { continue }
            switch e.name {
            case "r": try run(e, paragraphRun)
            case "hyperlink", "smartTag", "customXml", "dir", "bdo":
                try inline(e, paragraphRun)
            case "sdt":
                if let content = e.child(w, "sdtContent") { try inline(content, paragraphRun) }
            case "ins", "moveTo":
                skip("tracked-change")
                try inline(e, paragraphRun)
            case "del", "moveFrom":
                skip("tracked-change")
            case "fldSimple":
                let simple = Field()
                simple.inResult = true
                simple.outer = fields.isEmpty
                simple.format = paragraphRun
                simple.code += e.attribute(w, "instr") ?? ""
                classify(simple)
                fields.append(simple)
                try inline(e, paragraphRun)
                fields.removeLast()
            default: break
            }
        }
    }

    private func run(_ r: OfficeXmlElement, _ paragraphRun: RunProps) throws {
        let w = Self.w
        var props = paragraphRun
        styles.character(r.child(w, "rPr")?.child(w, "rStyle")?.attribute(w, "val"), &props, theme)
        props.apply(r.child(w, "rPr"), theme)
        content(r, props)
    }

    private func content(_ run: OfficeXmlElement, _ props: RunProps) {
        let w = Self.w
        for e in run.elements {
            if e.uri == Self.mc && e.name == "AlternateContent" {
                if let picked = Self.pick(e) { content(picked, props) }
                continue
            }
            if e.uri != w { continue }
            switch e.name {
            case "t": text(props, e.text)
            case "tab", "ptab": text(props, "\t")
            case "cr": text(props, "\n")
            case "noBreakHyphen": text(props, "\u{2011}")
            case "br":
                let kind = e.attribute(w, "type")
                if (kind == "page" || kind == "column") && !inBand && visible(props) {
                    breaker?()
                } else {
                    text(props, "\n")
                }
            case "instrText":
                if let open = fields.last, !open.inResult { open.code += e.text }
            case "fldChar": fieldChar(e.attribute(w, "fldCharType"), props)
            case "drawing": if visible(props) { skip(Self.drawing(e, "drawing")) }
            case "pict": if visible(props) { skip(Self.drawing(e, "shape")) }
            case "object": if visible(props) { skip("drawing") }
            case "footnoteReference": skip("footnote")
            case "endnoteReference": skip("endnote")
            case "commentReference": skip("comment")
            default: break
            }
        }
    }

    private func visible(_ props: RunProps) -> Bool { props.hidden != true && !suppressed }

    private var suppressed: Bool { fields.contains { !$0.inResult || $0.kind != .none } }

    private static func drawing(_ e: OfficeXmlElement, _ fallback: String) -> String {
        var text = false, chart = false, picture = false, shape = false
        func walk(_ x: OfficeXmlElement) {
            if x.uri == mc && x.name == "AlternateContent" {
                if let picked = pick(x) { walk(picked) }
                return
            }
            switch x.name {
            case "txbxContent", "textbox": text = true
            case "pic", "imagedata": picture = true
            case "wsp": shape = true
            case "graphicData":
                let uri = x.attribute("uri") ?? ""
                if uri.utf8.reversed().starts(with: "/chart".utf8.reversed()) {
                    chart = true
                } else if uri.utf8.reversed().starts(with: "/picture".utf8.reversed()) {
                    picture = true
                }
            default: break
            }
            for child in x.elements { walk(child) }
        }
        walk(e)
        return text ? "text-box" : chart ? "chart" : picture ? "picture" : shape ? "shape" : fallback
    }

    // ---- fields ----

    private func fieldChar(_ type: String?, _ props: RunProps) {
        switch type {
        case "begin":
            let field = Field()
            field.outer = fields.isEmpty
            field.format = props
            fields.append(field)
        case "separate":
            if let field = fields.last {
                field.inResult = true
                classify(field)
            }
        case "end":
            if let done = fields.popLast() { classify(done) }
        default: break
        }
    }

    // PAGE and NUMPAGES in a header or footer become field runs; every other field keeps the text it last showed.
    private func classify(_ field: Field) {
        if field.classified { return }
        field.classified = true
        let code = field.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(code.unicodeScalars)
        let space = scalars.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
        let name = Self.upper(String(String.UnicodeScalarView(space.map { Array(scalars[..<$0]) } ?? scalars)))
        if name == "PAGE" || name == "NUMPAGES" {
            if !inBand { return }
            field.kind = name == "PAGE" ? .pageNumber : .pageCount
            add(field.format, "", field.kind)
        } else if field.outer && name != "HYPERLINK" && !name.isEmpty {
            skip("field")
        }
    }

    // ---- text ----

    private func text(_ props: RunProps, _ text: String) {
        if text.isEmpty || !visible(props) { return }
        add(props, props.caps == true ? Self.upper(text) : text, .none)
    }

    // Plain ASCII only: full case mapping differs between the platforms.
    private static func upper(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { ("a"..."z").contains($0) ? Unicode.Scalar($0.value - 32)! : $0 }))
    }

    private func add(_ props: RunProps, _ text: String, _ field: LayoutField) {
        let format = Self.format(props, field)
        if field == .none, let last = pieces.last, Self.same(last.format, format) {
            last.text += text
            return
        }
        let piece = Piece(format)
        piece.text = text
        pieces.append(piece)
    }

    private static func same(_ a: LayoutRun, _ b: LayoutRun) -> Bool {
        a.field == .none && b.field == .none && a.family == b.family && a.size == b.size && a.bold == b.bold
            && a.italic == b.italic && a.underline == b.underline && a.strike == b.strike && a.color == b.color
            && a.highlight == b.highlight && a.shift == b.shift
    }

    private static func format(_ p: RunProps, _ field: LayoutField) -> LayoutRun {
        var size = p.size ?? 10
        var shift = 0.0
        if p.vertical == 1 {
            shift = size * 0.33
            size *= 2.0 / 3
        } else if p.vertical == -1 {
            shift = -size * 0.14
            size *= 2.0 / 3
        }
        let run = LayoutRun()
        run.family = p.family ?? "Times New Roman"
        run.size = size
        run.bold = p.bold == true
        run.italic = p.italic == true
        run.underline = p.underline == true
        run.strike = p.strike == true
        run.color = p.color ?? 0
        if let h = p.highlight, h >= 0 { run.highlight = h }
        run.shift = shift
        run.field = field
        return run
    }

    // ---- values ----

    static func on(_ e: OfficeXmlElement) -> Bool {
        let val = e.attribute(w, "val")
        return !(val == "0" || val == "false" || val == "off")
    }

    /// What .NET's double.Parse accepts with NumberStyles.Float and the invariant culture, finite values only.
    static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        let bytes = Array(text.utf8)
        func space(_ b: UInt8) -> Bool { b == 0x20 || (b >= 0x09 && b <= 0x0D) }
        func digit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        var start = 0, end = bytes.count
        while start < end && space(bytes[start]) { start += 1 }
        while end > start && space(bytes[end - 1]) { end -= 1 }
        var i = start
        var clean = ""
        if i < end && (bytes[i] == 0x2B || bytes[i] == 0x2D) {
            if bytes[i] == 0x2D { clean = "-" }
            i += 1
        }
        var whole = "", fraction = ""
        while i < end && digit(bytes[i]) { whole.append(Character(Unicode.Scalar(bytes[i]))); i += 1 }
        if i < end && bytes[i] == 0x2E {
            i += 1
            while i < end && digit(bytes[i]) { fraction.append(Character(Unicode.Scalar(bytes[i]))); i += 1 }
        }
        if whole.isEmpty && fraction.isEmpty { return nil }
        clean += (whole.isEmpty ? "0" : whole) + "." + (fraction.isEmpty ? "0" : fraction)
        if i < end && (bytes[i] == 0x45 || bytes[i] == 0x65) {
            i += 1
            var exponent = "e"
            if i < end && (bytes[i] == 0x2B || bytes[i] == 0x2D) {
                if bytes[i] == 0x2D { exponent += "-" }
                i += 1
            }
            var digits = 0
            while i < end && digit(bytes[i]) { exponent.append(Character(Unicode.Scalar(bytes[i]))); i += 1; digits += 1 }
            if digits == 0 { return nil }
            clean += exponent
        }
        if i != end { return nil }
        guard let value = Double(clean), value.isFinite else { return nil }
        return value
    }

    static func hex(_ text: String?) -> Int? {
        guard let text, text.utf8.count == 6, text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        return Int(text, radix: 16)
    }

    static func highlightColor(_ name: String) -> Int? { highlights[name] }
}
