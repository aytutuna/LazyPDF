import Foundation

// Twin of windows/LazyPDF.Core/Office/Pptx/PptxReader.cs: reads a .pptx package into a `PptxPresentation`: the slides in order
// with their background and the shapes that can be drawn, positioned in points and with text resolved through slide, layout,
// master and presentation defaults. Hidden slides are left out. What it does not carry over is counted in
// `PptxPresentation.skipped`.

final class PptxReader {
    static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"
    static let emuPerPoint = 12700.0
    private static let defaultWidth = 720.0, defaultHeight = 540.0

    final class Placeholder {
        let type: String?
        let index: Int
        let shape: OfficeXmlElement
        let group: String

        init(_ type: String?, _ index: Int, _ shape: OfficeXmlElement) {
            self.type = type
            self.index = index
            self.shape = shape
            group = PptxReader.groupOf(type)
        }
    }

    // A slide master or a slide layout, read once however many slides use it.
    final class Template {
        let root: OfficeXmlElement
        let relationships: [OpcRelationship]
        let colors: PptxColors
        let placeholders: [Placeholder]
        let master: Template?
        let theme: OfficeXmlElement?
        let showMasterShapes: Bool
        // The layout's own shapes and the master's as they come out under this layout's color map.
        var shapes: [PptxShape]?
        var masterShapes: [PptxShape]?

        init(root: OfficeXmlElement, relationships: [OpcRelationship], colors: PptxColors, placeholders: [Placeholder],
             master: Template? = nil, theme: OfficeXmlElement?, showMasterShapes: Bool = true) {
            self.root = root
            self.relationships = relationships
            self.colors = colors
            self.placeholders = placeholders
            self.master = master
            self.theme = theme
            self.showMasterShapes = showMasterShapes
        }
    }

    struct Scope {
        let layout: Template?
        let master: Template
        let colors: PptxColors
        let isSlide: Bool
        let relationships: [OpcRelationship]
    }

    private struct BackgroundSays {
        let value: PptxBackground?
    }

    private let package: OpcPackage
    let limits: PptxLimits
    private var skipped: [String: Int] = [:]
    private var masters: [String: Template] = [:]
    private var layouts: [String: Template] = [:]
    private var pictures: [String: PictureFile] = [:]
    var defaultStyle: OfficeXmlElement?
    private var width = PptxReader.defaultWidth, height = PptxReader.defaultHeight
    var totalText = 0
    private var drawn = 0
    private var pictureCount = 0

    private init(_ package: OpcPackage, _ limits: PptxLimits) {
        self.package = package
        self.limits = limits
    }

    static func read(_ data: [UInt8], _ limits: PptxLimits = .standard) throws -> PptxPresentation {
        if data.count >= 4 && data[0] == 0xD0 && data[1] == 0xCF && data[2] == 0x11 && data[3] == 0xE0 {
            throw PdfReadException(.unsupported, "This is a PowerPoint 97-2003 file. Save it as .pptx first.")
        }
        return try PptxReader(try OpcPackage.open(data), limits).run()
    }

    private func run() throws -> PptxPresentation {
        let p = Self.p, r = Self.r
        guard let main = try package.relationships("").first(where: { $0.type == OpcPackage.officeDocument })?.target else {
            throw PdfReadException.damaged("The file has no main presentation part.")
        }
        if !package.contains(main) { throw PdfReadException.damaged("The package has no part \(main).") }
        guard let type = package.contentType(main), XlsxReader.contains(type, "presentationml") else {
            throw PdfReadException(.unsupported, "The file is not a PowerPoint presentation.")
        }
        let root = try package.xml(main)
        if root.uri != p || root.name != "presentation" {
            throw PdfReadException(.unsupported, "The presentation is not in the PowerPoint 2007 format.")
        }

        let size = root.child(p, "sldSz")
        width = Self.side(size, "cx", Self.defaultWidth)
        height = Self.side(size, "cy", Self.defaultHeight)
        defaultStyle = root.child(p, "defaultTextStyle")
        let first = Int(PptxColors.clamp(DocxReader.number(root.attribute("firstSlideNum")) ?? 1, 0, 32767))

        let relationships = try package.relationships(main)
        let ids = root.child(p, "sldIdLst")?.elements(p, "sldId") ?? []
        if ids.count > limits.maxSlides { throw PdfReadException(.unsupported, "The presentation has too many slides.") }

        var presentation = PptxPresentation(width: width, height: height)
        for (i, entry) in ids.enumerated() {
            try Task.checkCancellation()
            let id = entry.attribute(r, "id")
            guard let target = relationships.first(where: { $0.id == id && XlsxReader.endsWith($0.type, "/slide") })?.target,
                  package.contains(target) else { continue }
            let slide = try package.xml(target)
            if slide.uri != p || slide.name != "sld" { continue }
            let show = slide.attribute("show")
            if show == "0" || show == "false" {
                skip(PptxSkipped.hiddenSlide)
                continue
            }
            presentation.slides.append(try makeSlide(slide, target, first + i))
        }
        if presentation.slides.isEmpty { throw PdfReadException(.unsupported, "The presentation has no slides to show.") }
        for kind in skipped.keys.sorted() { presentation.skipped.append(SkippedFeature(kind, skipped[kind]!)) }
        return presentation
    }

    private static func side(_ size: OfficeXmlElement?, _ name: String, _ fallback: Double) -> Double {
        if let emu = DocxReader.number(size?.attribute(name)), emu > 0 {
            return PptxColors.clamp(emu / emuPerPoint, PptxLimits.minSide, PptxLimits.maxSide)
        }
        return fallback
    }

    func skip(_ kind: String, _ count: Int = 1) { skipped[kind, default: 0] += count }

    // ---- masters and layouts ----

    private func master(_ part: String?) throws -> Template {
        let part = part ?? ""
        if let known = masters[part] { return known }
        let present = !part.isEmpty && package.contains(part)
        let root = try present ? package.xml(part) : OfficeXmlElement(uri: Self.p, name: "sldMaster", attributes: [])
        let relationships = try present ? package.relationships(part) : []
        let themePart = relationships.first { XlsxReader.endsWith($0.type, "/theme") }?.target
        var themeRoot: OfficeXmlElement?
        if let themePart, package.contains(themePart) { themeRoot = try package.xml(themePart) }
        let colors = PptxColors(DocxTheme.read(themeRoot), PptxColors.readMap(root.child(Self.p, "clrMap")))
        let template = Template(root: root, relationships: relationships, colors: colors, placeholders: Self.placeholders(root), theme: themeRoot)
        masters[part] = template
        return template
    }

    private func layout(_ part: String?) throws -> Template {
        let part = part ?? ""
        if let known = layouts[part] { return known }
        let present = !part.isEmpty && package.contains(part)
        let root = try present ? package.xml(part) : OfficeXmlElement(uri: Self.p, name: "sldLayout", attributes: [])
        let relationships = try present ? package.relationships(part) : []
        let master = try master(relationships.first { XlsxReader.endsWith($0.type, "/slideMaster") }?.target)
        let show = root.attribute("showMasterSp")
        let template = Template(root: root, relationships: relationships, colors: Self.remapped(root, master.colors), placeholders: Self.placeholders(root),
                                master: master, theme: master.theme, showMasterShapes: !(show == "0" || show == "false"))
        layouts[part] = template
        return template
    }

    private static func remapped(_ root: OfficeXmlElement, _ inherited: PptxColors) -> PptxColors {
        if let over = root.child(p, "clrMapOvr")?.child(DocxReader.a, "overrideClrMapping") { return inherited.withMap(PptxColors.readMap(over)) }
        return inherited
    }

    static func tree(_ root: OfficeXmlElement) -> OfficeXmlElement? { root.child(p, "cSld")?.child(p, "spTree") }

    static func placeholderOf(_ shape: OfficeXmlElement) -> OfficeXmlElement? {
        shape.child(p, "nvSpPr")?.child(p, "nvPr")?.child(p, "ph")
    }

    private static func placeholders(_ root: OfficeXmlElement) -> [Placeholder] {
        var list: [Placeholder] = []
        for sp in children(tree(root)) where sp.uri == p && sp.name == "sp" {
            guard let ph = placeholderOf(sp) else { continue }
            let index = Int(PptxColors.clamp(DocxReader.number(ph.attribute("idx")) ?? 0, 0, Double(Int32.max)))
            list.append(Placeholder(ph.attribute("type"), index, sp))
        }
        return list
    }

    static func groupOf(_ type: String?) -> String {
        switch type {
        case "title", "ctrTitle": return "title"
        case "dt": return "dt"
        case "ftr": return "ftr"
        case "sldNum": return "sldNum"
        case "hdr": return "hdr"
        default: return "body"
        }
    }

    // A slide placeholder finds its twin in the layout by index first; a layout placeholder finds its twin in the master by kind.
    static func match(_ list: [Placeholder], _ type: String?, _ index: Int, _ byIndex: Bool) -> Placeholder? {
        let group = groupOf(type)
        if byIndex, let exact = list.first(where: { $0.index == index && $0.group == group }) { return exact }
        return list.first { $0.group == group }
    }

    static func children(_ tree: OfficeXmlElement?) -> [OfficeXmlElement] {
        var result: [OfficeXmlElement] = []
        for e in tree?.elements ?? [] {
            if e.uri == mc && e.name == "AlternateContent" {
                let picked = e.elements(mc, "Choice").first ?? e.elements(mc, "Fallback").first
                result.append(contentsOf: children(picked))
            } else {
                result.append(e)
            }
        }
        return result
    }

    // ---- slides ----

    private func makeSlide(_ root: OfficeXmlElement, _ part: String, _ number: Int) throws -> PptxSlide {
        let relationships = try package.relationships(part)
        let layout = try layout(relationships.first { XlsxReader.endsWith($0.type, "/slideLayout") }?.target)
        let master = layout.master!
        let colors = Self.remapped(root, layout.colors)
        let overridden = root.child(Self.p, "clrMapOvr")?.child(DocxReader.a, "overrideClrMapping") != nil

        var shapes: [PptxShape] = []
        let show = root.attribute("showMasterSp")
        if !(show == "0" || show == "false") {
            if layout.showMasterShapes {
                shapes.append(contentsOf: try inherited(master, master, colors, overridden, &layout.masterShapes))
            }
            shapes.append(contentsOf: try inherited(layout, master, colors, overridden, &layout.shapes))
        }
        shapes.append(contentsOf: try slideShapes(root, Scope(layout: layout, master: master, colors: colors, isSlide: true, relationships: relationships)))
        drawn += shapes.count
        if drawn > limits.maxDrawnShapes { throw PdfReadException(.unsupported, "The presentation has too many shapes.") }

        return PptxSlide(number: number, background: try background(root, relationships, colors, layout, master), shapes: shapes)
    }

    // A slide that overrides the color map gets its own copy; the others share what the layout cached.
    private func inherited(_ source: Template, _ master: Template, _ colors: PptxColors, _ overridden: Bool, _ cache: inout [PptxShape]?) throws -> [PptxShape] {
        let scope = Scope(layout: nil, master: master, colors: colors, isSlide: false, relationships: source.relationships)
        if overridden { return try staticShapes(source, scope) }
        if cache == nil { cache = try staticShapes(source, scope) }
        return cache!
    }

    // ---- backgrounds ----

    private func background(_ slide: OfficeXmlElement, _ relationships: [OpcRelationship], _ colors: PptxColors, _ layout: Template, _ master: Template) throws -> PptxBackground? {
        if let own = try background(slide, relationships, colors, master.theme) { return own.value }
        if let inherited = try background(layout.root, layout.relationships, colors, master.theme) { return inherited.value }
        return try background(master.root, master.relationships, colors, master.theme)?.value
    }

    // Nil when the part says nothing about its background; else what it says, which may be nothing.
    private func background(_ root: OfficeXmlElement, _ relationships: [OpcRelationship], _ colors: PptxColors, _ theme: OfficeXmlElement?) throws -> BackgroundSays? {
        let p = Self.p, a = DocxReader.a
        guard let bg = root.child(p, "cSld")?.child(p, "bg") else { return nil }
        if let properties = bg.child(p, "bgPr") {
            for e in properties.elements where e.uri == a {
                switch e.name {
                case "solidFill": return BackgroundSays(value: PptxBackground(color: colors.first(e), picture: nil))
                case "gradFill":
                    skip(PptxSkipped.gradient)
                    return BackgroundSays(value: PptxBackground(color: colors.first(e.child(a, "gsLst")?.child(a, "gs")), picture: nil))
                case "blipFill": return BackgroundSays(value: PptxBackground(color: nil, picture: try picture(e, relationships, width, height)))
                case "noFill", "pattFill", "grpFill": return BackgroundSays(value: nil)
                default: break
                }
            }
            return nil
        }
        if let reference = bg.child(p, "bgRef") {
            var color = colors.first(reference)
            // 1001 and up name an entry of the theme's background fills, which holds the color of the reference as phClr.
            if let idx = DocxReader.number(reference.attribute("idx")), idx >= 1001, color != nil {
                let list = theme?.child(a, "themeElements")?.child(a, "fmtScheme")?.child(a, "bgFillStyleLst")?.elements ?? []
                let at = idx - 1001
                if at < Double(list.count) {
                    let entry = list[Int(at)]
                    if entry.name == "solidFill" {
                        color = colors.first(entry, color) ?? color
                    } else if entry.name == "gradFill" {
                        skip(PptxSkipped.gradient)
                        color = colors.first(entry.child(a, "gsLst")?.child(a, "gs"), color) ?? color
                    }
                }
            }
            return BackgroundSays(value: PptxBackground(color: color, picture: nil))
        }
        return nil
    }

    // A picture of the given size in points; a missing or linked picture is counted as an unreadable one.
    func picture(_ blipFill: OfficeXmlElement, _ relationships: [OpcRelationship], _ width: Double, _ height: Double) throws -> LayoutPicture? {
        let id = blipFill.child(DocxReader.a, "blip")?.attribute(Self.r, "embed")
        let target = id.flatMap { id in relationships.first { $0.id == id && XlsxReader.endsWith($0.type, "/image") }?.target }
        guard let target, package.contains(target) else {
            skip(SkippedKinds.unreadablePicture)
            return nil
        }
        pictureCount += 1
        if pictureCount > limits.maxPictures {
            skip(SkippedKinds.unreadablePicture)
            return nil
        }
        let key = ZipReader.key(target)
        if pictures[key] == nil { pictures[key] = PictureFile(try package.bytes(target)) }
        let crop = blipFill.child(DocxReader.a, "srcRect")
        func edge(_ name: String) -> Double { PptxColors.clamp((DocxReader.number(crop?.attribute(name)) ?? 0) / 100_000, 0, 0.95) }
        return LayoutPicture(pictures[key]!, width, height, cropLeft: edge("l"), cropTop: edge("t"), cropRight: edge("r"), cropBottom: edge("b"))
    }
}
