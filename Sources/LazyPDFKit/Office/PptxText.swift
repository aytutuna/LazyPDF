import Foundation

// Twin of windows/LazyPDF.Core/Office/Pptx/PptxText.cs: the text of a slide shape.

extension PptxReader {
    private static let leftInset = 7.2, topInset = 3.6
    private static let levels = 9
    private static let defaultSize = 18.0

    // The room and paragraphs of a shape's text, or nil when the shape holds no text.
    func makeBody(_ txBody: OfficeXmlElement, _ ph: OfficeXmlElement?, _ layoutPh: Placeholder?, _ masterPh: Placeholder?, _ scope: Scope, _ style: OfficeXmlElement?) throws -> PptxBody? {
        let p = Self.p, a = DocxReader.a
        var layers: [OfficeXmlElement?] = [defaultStyle]
        var box = PptxBodyProps()
        if let ph {
            let styles = scope.master.root.child(p, "txStyles")
            let group = Self.groupOf(ph.attribute("type") ?? layoutPh?.type)
            layers.append(styles?.child(p, group == "title" ? "titleStyle" : group == "body" ? "bodyStyle" : "otherStyle"))
            for template in [masterPh, layoutPh] {
                let body = template?.shape.child(p, "txBody")
                layers.append(body?.child(a, "lstStyle"))
                box.apply(body?.child(a, "bodyPr"))
            }
        }
        layers.append(txBody.child(a, "lstStyle"))
        box.apply(txBody.child(a, "bodyPr"))

        let fontColor = scope.colors.first(style?.child(a, "fontRef"))
        let (paragraphs, any) = try makeParagraphs(txBody, layers, scope.colors, box, fontColor)
        if !any { return nil }
        if box.rotated { skip(PptxSkipped.textRotation) }
        return PptxBody(left: box.left ?? Self.leftInset, top: box.top ?? Self.topInset, right: box.right ?? Self.leftInset,
                        bottom: box.bottom ?? Self.topInset, anchor: box.anchor ?? .top, wrap: box.wrap ?? true, paragraphs: paragraphs)
    }

    private static func level(_ layers: [OfficeXmlElement?], _ level: Int, _ colors: PptxColors) -> PptxLevelProps {
        var props = PptxLevelProps()
        for layer in layers {
            props.apply(layer?.child(DocxReader.a, "defPPr"), colors)
            props.apply(layer?.child(DocxReader.a, "lvl\(level + 1)pPr"), colors)
        }
        return props
    }

    func makeParagraphs(_ txBody: OfficeXmlElement, _ layers: [OfficeXmlElement?], _ colors: PptxColors, _ box: PptxBodyProps, _ fontColor: Int?) throws -> ([LayoutParagraph], Bool) {
        let a = DocxReader.a
        var result: [LayoutParagraph] = []
        var counters = [Int](repeating: 0, count: Self.levels)
        var schemes = [String?](repeating: nil, count: Self.levels)
        var paragraphs = 0, chars = 0
        var cut = false
        var any = false
        for p in txBody.elements(a, "p") {
            paragraphs += 1
            if paragraphs > limits.maxParagraphs {
                cut = true
                break
            }
            try Task.checkCancellation()
            let pPr = p.child(a, "pPr")
            let level = Int(PptxColors.clamp(DocxReader.number(pPr?.attribute("lvl")) ?? 0, 0, Double(Self.levels - 1)))
            var props = Self.level(layers, level, colors)
            if let fontColor { props.run.color = fontColor }
            props.apply(pPr, colors)

            var runs: [LayoutRun] = []
            for e in p.elements where e.uri == a {
                var text: String?
                let rPr = e.child(a, "rPr")
                var field = LayoutField.none
                switch e.name {
                case "r": text = e.child(a, "t")?.text
                case "br": text = "\n"
                case "fld":
                    text = e.child(a, "t")?.text
                    if e.attribute("type") == "slidenum" { field = .pageNumber }
                default: break
                }
                if field == .none && (text ?? "").isEmpty { continue }
                var units = Array((text ?? "").utf16)
                if chars + units.count > limits.maxTextLength {
                    cut = true
                    var room = max(0, limits.maxTextLength - chars)
                    if room > 0 && units[room - 1] >= 0xD800 && units[room - 1] < 0xDC00 { room -= 1 }
                    units = Array(units[..<room])
                }
                chars += units.count
                totalText += units.count
                if totalText > limits.maxTotalText { throw PdfReadException(.unsupported, "The presentation has too much text.") }
                if units.isEmpty && field == .none { continue }
                runs.append(contentsOf: Self.makeRuns(props.run, rPr, String(decoding: units, as: UTF16.self), field, colors, box.fontScale))
            }

            let hasText = !runs.isEmpty
            any = any || hasText
            if !hasText { runs.append(Self.makeRun(props.run, p.child(a, "endParaRPr"), "", .none, colors, box.fontScale)) }

            let label = hasText ? Self.bullet(props, level, &counters, &schemes) : nil
            if hasText { Self.reset(&counters, &schemes, props.bulletKind == "auto" ? level + 1 : level) }
            var labelTab: Double?
            if let label {
                runs.insert(Self.labelRun(props, runs[0], label), at: 0)
                if (props.indent ?? 0) < 0 { labelTab = props.marL ?? 0 }
            }
            result.append(Self.makeParagraph(props, runs, labelTab, box))
            if cut { break }
        }
        if cut { skip(PptxSkipped.textCut) }
        return (result, any)
    }

    private static func reset(_ counters: inout [Int], _ schemes: inout [String?], _ from: Int) {
        if from >= counters.count { return }
        for i in from..<counters.count {
            counters[i] = 0
            schemes[i] = nil
        }
    }

    // Hebrew and Arabic letters take the complex-script font; a field is never cut.
    private static func makeRuns(_ inherited: PptxRunProps, _ rPr: OfficeXmlElement?, _ text: String, _ field: LayoutField, _ colors: PptxColors, _ scale: Double) -> [LayoutRun] {
        if field != .none || text.isEmpty { return [makeRun(inherited, rPr, text, field, colors, scale)] }
        return ScriptRuns.split(text).map { makeRun(inherited, rPr, $0.text, field, colors, scale, $0.complex) }
    }

    private static func makeRun(_ inherited: PptxRunProps, _ rPr: OfficeXmlElement?, _ text: String, _ field: LayoutField, _ colors: PptxColors, _ scale: Double, _ complex: Bool = false) -> LayoutRun {
        var props = inherited
        props.apply(rPr, colors)
        var size = (props.size ?? defaultSize) * scale
        var shift = 0.0
        if let baseline = props.baseline, baseline != 0 {
            shift = size * baseline / 100
            size *= 2.0 / 3
        }
        let link = props.link == true
        let run = LayoutRun()
        run.text = props.caps == true ? DocxReader.upper(text) : text
        run.family = (complex ? props.csFamily : nil) ?? props.family ?? colors.theme.font("minor") ?? "Calibri"
        run.size = size
        run.bold = props.bold == true
        run.italic = props.italic == true
        run.underline = props.underline == true || link
        run.strike = props.strike == true
        run.color = (link ? colors.hyperlink : nil) ?? props.color ?? 0
        run.highlight = props.highlight
        run.shift = shift
        run.field = field
        run.rtl = props.rtl == true
        return run
    }

    // The text of the bullet or number in front of a paragraph, or nil for none. Numbers run on through paragraphs of one
    // level that use the same scheme; a paragraph without a number ends the run, and so does one on a higher level.
    private static func bullet(_ props: PptxLevelProps, _ level: Int, _ counters: inout [Int], _ schemes: inout [String?]) -> String? {
        if props.bulletKind == "char" { return props.bulletChar.map { symbols($0, props.bulletFont) } }
        guard props.bulletKind == "auto", let type = props.autoType else { return nil }
        counters[level] = schemes[level] == type && counters[level] > 0 ? counters[level] + 1 : props.autoStart ?? 1
        schemes[level] = type
        return autoNumber(type, counters[level])
    }

    private static func symbols(_ text: String, _ font: String?) -> String {
        guard let font, isSymbolFont(font) else { return text }
        return String(decoding: text.utf16.map { DocxNumbering.symbolBullet(Int($0 & 0xFF)) }, as: UTF16.self)
    }

    private static func autoNumber(_ type: String, _ value: Int) -> String {
        let upper = XlsxReader.contains(type, "Uc")
        let format = type.utf8.starts(with: "roman".utf8) ? (upper ? "upperRoman" : "lowerRoman")
            : type.utf8.starts(with: "alpha".utf8) ? (upper ? "upperLetter" : "lowerLetter")
            : "decimal"
        let number = DocxNumbering.format(value, format)
        if XlsxReader.endsWith(type, "ParenBoth") { return "(" + number + ")" }
        if XlsxReader.endsWith(type, "ParenR") { return number + ")" }
        if XlsxReader.endsWith(type, "Plain") { return number }
        return number + "."
    }

    private static func labelRun(_ props: PptxLevelProps, _ first: LayoutRun, _ label: String) -> LayoutRun {
        let symbol = props.bulletKind == "char"
        let run = LayoutRun()
        run.text = label + "\t"
        if let font = props.bulletFont, symbol, !isSymbolFont(font) { run.family = font } else { run.family = first.family }
        run.size = props.bulletPoints ?? first.size * (props.bulletPercent ?? 1)
        run.bold = !symbol && first.bold
        run.italic = !symbol && first.italic
        run.color = props.bulletColor ?? first.color
        return run
    }

    // Wingdings, Symbol or a Wingdings variant, compared without regard to ASCII case.
    private static func isSymbolFont(_ font: String) -> Bool {
        let folded = font.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
        return folded == Array("wingdings".utf8) || folded == Array("symbol".utf8) || folded.starts(with: Array("wingdings ".utf8))
    }

    private static func makeParagraph(_ props: PptxLevelProps, _ runs: [LayoutRun], _ labelTab: Double?, _ box: PptxBodyProps) -> LayoutParagraph {
        let size = runs.map { $0.size }.max()!
        var rule = LineRule.multiple
        var spacing = 1.0
        if let exact = props.line, exact.points {
            rule = .exact
            spacing = max(1, exact.value)
        } else {
            spacing = max(0.1, (props.line?.value ?? 1) - box.lineReduction)
        }
        let paragraph = LayoutParagraph()
        paragraph.runs = runs
        paragraph.align = props.align ?? (props.rtl == true ? .right : .left)
        paragraph.rightToLeft = props.rtl == true
        paragraph.left = props.marL ?? 0
        paragraph.firstLine = props.indent ?? 0
        paragraph.before = space(props.before, size)
        paragraph.after = space(props.after, size)
        paragraph.lineSpacing = spacing
        paragraph.rule = rule
        paragraph.labelTab = labelTab
        return paragraph
    }

    // A percentage is of the line, which is a little over the font size.
    private static func space(_ spacing: PptxSpacing?, _ size: Double) -> Double {
        guard let s = spacing else { return 0 }
        return s.points ? s.value : s.value * size * 1.2
    }
}
