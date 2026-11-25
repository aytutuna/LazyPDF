import Foundation

// Twin of windows/LazyPDF.Core/Forms/PdfForm.cs: the AcroForm of a document (ISO 32000-1 12.7): its fields read with
// inheritance, filled, authored, calculated and flattened. It works on the open `PdfDocument` in memory; the edit session
// commits it. A field whose value changes always gets a new appearance stream, because the system renderer ignores
// /NeedAppearances and keeps a stale /AP. Fields are read again after every change made through this class; call `refresh`
// after changing dictionaries by hand.

public final class PdfForm {
    static let maxFields = 200_000
    static let maxDepth = 32

    public let document: PdfDocument
    let fonts: FontSource?
    public internal(set) var fields: [FormField] = []
    var byName: [[UInt16]: [FormField]] = [:]
    var byDictionary: [ObjectIdentifier: FormField] = [:]
    var byWidget: [ObjectIdentifier: FormField] = [:]
    var undrawn: Set<Int> = []

    /// The /XFA entry was taken out by a change to a static XFA form (see `FormText.xfaRemoved`).
    public internal(set) var xfaRemoved = false

    private init(_ document: PdfDocument, _ fonts: FontSource?) {
        self.document = document
        self.fonts = fonts
    }

    /// Reads the form; a document without an /AcroForm gives an empty one. `fonts` finds font files for text the form's own
    /// fonts cannot show (Turkish g, s, i in a Latin-1 font).
    public static func read(_ document: PdfDocument, _ fonts: FontSource? = nil) -> PdfForm {
        let form = PdfForm(document, fonts)
        form.refresh()
        return form
    }

    public var acroForm: PdfDictionary? { document.dict(document.catalog, "AcroForm") }

    /// Widgets a page lists whose field is not reachable from /AcroForm /Fields.
    public var orphans: [FormField] { fields.filter { $0.isOrphan } }

    /// /NeedAppearances is set: the file's maker says its appearances are stale.
    public var needAppearances: Bool { document.bool(acroForm, "NeedAppearances") == true }

    /// The XFA form behind the AcroForm, if any. Dynamic forms are refused by everything that changes the form.
    public var xfa: XfaKind {
        if !document.hasXfa { return .none }
        return fields.isEmpty ? .dynamic : .static
    }

    /// False for an encrypted file opened with the user password whose permissions allow neither filling forms nor
    /// annotating; enforcing it is the app's call.
    public var canFill: Bool {
        guard let security = document.security else { return true }
        return security.openedAsOwner || security.permissions.contains(.fillForms) || security.permissions.contains(.annotate)
    }

    public func find(_ name: String) -> FormField? { byName[Array(name.utf16)]?.first }

    /// All fields with the name: a name two fields share is one field to the user, and both change together.
    public func findAll(_ name: String) -> [FormField] { byName[Array(name.utf16)] ?? [] }

    // The C# widget holds its field strongly. Here the link is weak, because the fields are read again after every change, so
    // a widget a caller kept is looked up in the current fields.
    func fieldOf(_ widget: FormWidget) -> FormField? { byWidget[ObjectIdentifier(widget.dictionary)] ?? widget.field }

    public func refresh() {
        let pages = scanWidgets()
        var seen = Set<ObjectIdentifier>()
        var found: [FormField] = []
        if let roots = document.array(acroForm, "Fields") {
            for item in roots.items {
                if found.count >= Self.maxFields { break }
                walk(item, [], &seen, &found, pages)
            }
        }
        addOrphans(pages, &seen, &found)
        fields = found
        byName = [:]
        byDictionary = [:]
        byWidget = [:]
        for field in found {
            for widget in field.widgets where byWidget[ObjectIdentifier(widget.dictionary)] == nil { byWidget[ObjectIdentifier(widget.dictionary)] = field }
            if byDictionary[ObjectIdentifier(field.dictionary)] == nil { byDictionary[ObjectIdentifier(field.dictionary)] = field }
            byName[Array(field.name.utf16), default: []].append(field)
        }
    }

    private struct Scanned {
        let dictionary: PdfDictionary
        let reference: PdfReference?
        let pageIndex: Int
    }

    private struct WidgetScan {
        var all: [Scanned] = []
        var pageOf: [ObjectIdentifier: Int] = [:]
    }

    private func scanWidgets() -> WidgetScan {
        var scan = WidgetScan()
        for page in document.pages {
            guard let annots = document.array(page.dictionary, "Annots") else { continue }
            for item in annots.items.prefix(PdfAnnotations.maxAnnotations) {
                if scan.all.count >= Self.maxFields { return scan }
                if let d = document.resolve(item) as? PdfDictionary, document.name(d, "Subtype") == "Widget",
                   scan.pageOf[ObjectIdentifier(d)] == nil {
                    scan.pageOf[ObjectIdentifier(d)] = page.index
                    scan.all.append(Scanned(dictionary: d, reference: item as? PdfReference, pageIndex: page.index))
                }
            }
        }
        return scan
    }

    private func walk(_ item: PdfObject?, _ chain: [PdfDictionary], _ seen: inout Set<ObjectIdentifier>, _ found: inout [FormField], _ pages: WidgetScan) {
        if found.count >= Self.maxFields || chain.count > Self.maxDepth { return }
        guard let node = document.resolve(item) as? PdfDictionary, seen.insert(ObjectIdentifier(node)).inserted else { return }

        let kids = kidsOf(node)
        let fieldKids = kids.filter { isFieldNode($0.dictionary) }
        if !fieldKids.isEmpty {
            let next = chain + [node]
            for kid in fieldKids { walk(kid.item, next, &seen, &found, pages) }
            return
        }
        var widgets = kids
        if document.name(node, "Subtype") == "Widget", let item {
            widgets.insert((item, node), at: 0)
        }
        for widget in widgets { seen.insert(ObjectIdentifier(widget.dictionary)) }
        if let field = build(node, item as? PdfReference, chain, widgets, pages, orphan: false) { found.append(field) }
    }

    private func kidsOf(_ node: PdfDictionary) -> [(item: PdfObject, dictionary: PdfDictionary)] {
        var kids: [(item: PdfObject, dictionary: PdfDictionary)] = []
        guard let array = document.array(node, "Kids") else { return kids }
        for item in array.items.prefix(Self.maxFields) {
            if let d = document.resolve(item) as? PdfDictionary { kids.append((item, d)) }
        }
        return kids
    }

    private func isFieldNode(_ d: PdfDictionary) -> Bool {
        d.containsKey("T") || (d.containsKey("Kids") && document.name(d, "Subtype") != "Widget")
    }

    private func addOrphans(_ pages: WidgetScan, _ seen: inout Set<ObjectIdentifier>, _ found: inout [FormField]) {
        var groups: [ObjectIdentifier: (reference: PdfReference?, widgets: [(item: PdfObject, dictionary: PdfDictionary)])] = [:]
        var order: [PdfDictionary] = []
        for scanned in pages.all {
            if seen.contains(ObjectIdentifier(scanned.dictionary)) { continue }
            let parent = document.dict(scanned.dictionary, "Parent")
            var key = scanned.dictionary
            if let parent, !scanned.dictionary.containsKey("T") { key = parent }
            let id = ObjectIdentifier(key)
            if groups[id] == nil {
                let reference = key === scanned.dictionary ? scanned.reference : scanned.dictionary["Parent"] as? PdfReference
                groups[id] = (reference, [])
                order.append(key)
            }
            groups[id]?.widgets.append((scanned.reference ?? scanned.dictionary, scanned.dictionary))
        }
        for key in order {
            if found.count >= Self.maxFields { return }
            guard let group = groups[ObjectIdentifier(key)] else { continue }
            var chain: [PdfDictionary] = []
            var up = document.dict(key, "Parent")
            while let current = up, chain.count < Self.maxDepth, !chain.contains(where: { $0 === current }) {
                chain.insert(current, at: 0)
                up = document.dict(current, "Parent")
            }
            if let field = build(key, group.reference, chain, group.widgets, pages, orphan: true) { found.append(field) }
        }
    }

    private func build(_ node: PdfDictionary, _ reference: PdfReference?, _ chain: [PdfDictionary], _ widgets: [(item: PdfObject, dictionary: PdfDictionary)], _ pages: WidgetScan, orphan: Bool) -> FormField? {
        guard let ft = document.resolve(inherited(node, chain, "FT")) as? PdfName else { return nil }
        let flags = FieldFlags(rawValue: (document.resolve(inherited(node, chain, "Ff")) as? PdfNumber)?.integer ?? 0).intersection(FieldFlags(rawValue: 0x7FFF_FFFF))
        let kind: FieldKind
        switch ft.value {
        case "Btn": kind = flags.contains(.pushButton) ? .pushButton : flags.contains(.radio) ? .radio : .checkBox
        case "Tx": kind = .text
        case "Ch": kind = flags.contains(.combo) ? .comboBox : .listBox
        case "Sig": kind = .signature
        default: return nil
        }

        let names = (chain + [node]).compactMap { PdfText.read(document, $0, "T") }
        let partial = PdfText.read(document, node, "T") ?? ""
        let options = readOptions(inherited(node, chain, "Opt"))
        let values = strings(inherited(node, chain, "V"))
        let acro = acroForm
        let field = FormField(node, reference, names.joined(separator: "."), partial, kind, flags)
        field.selected = kind == .comboBox || kind == .listBox ? values : []
        field.defaultValue = strings(inherited(node, chain, "DV")).first
        field.defaultAppearance = PdfText.read(document, inherited(node, chain, "DA")) ?? PdfText.read(document, acro, "DA")
        let quadding = (document.resolve(inherited(node, chain, "Q")) as? PdfNumber)?.integer ?? document.integer(acro, "Q") ?? 0
        field.alignment = Int(Int32(truncatingIfNeeded: quadding))
        field.maxLength = min(max((document.resolve(inherited(node, chain, "MaxLen")) as? PdfNumber)?.integer ?? 0, 0), Int(Int32.max))
        field.options = options
        field.tooltip = PdfText.read(document, node, "TU")
        field.isOrphan = orphan
        var built: [FormWidget] = []
        for (item, d) in widgets {
            let on = onStateOf(d)
            var export = on
            if kind == .radio && options.count > built.count { export = options[built.count].export }
            let rect = document.rect(d, "Rect") ?? PdfRect(0, 0, 0, 0)
            let widget = FormWidget(d, item as? PdfReference, pages.pageOf[ObjectIdentifier(d)] ?? -1, rect, on, export)
            widget.field = field
            widget.isOn = on != nil && document.name(d, "AS") == on
            built.append(widget)
        }
        field.widgets = built
        field.value = valueOf(kind, values, built)
        return field
    }

    private func valueOf(_ kind: FieldKind, _ values: [String], _ widgets: [FormWidget]) -> String? {
        if kind == .checkBox || kind == .radio {
            var state = values.first
            if state == nil || state == "" {
                state = widgets.compactMap { document.name($0.dictionary, "AS") }.first { $0 != "Off" }
            }
            guard let chosen = state, chosen != "", chosen != "Off" else { return "Off" }
            return widgets.first { $0.onState == chosen }?.export ?? chosen
        }
        if kind == .pushButton || kind == .signature { return nil }
        return values.first
    }

    func inherited(_ node: PdfDictionary, _ chain: [PdfDictionary], _ key: String) -> PdfObject? {
        if let own = present(node[key]) { return own }
        for dictionary in chain.reversed() {
            if let value = present(dictionary[key]) { return value }
        }
        return nil
    }

    func present(_ value: PdfObject?) -> PdfObject? {
        let resolved = document.resolve(value)
        return resolved == nil || resolved is PdfNull ? nil : value
    }

    func strings(_ value: PdfObject?) -> [String] {
        switch document.resolve(value) {
        case let name as PdfName:
            return [name.value]
        case is PdfString, is PdfStream:
            if let text = PdfText.read(document, value) { return [text] }
            return []
        case let array as PdfArray:
            return array.items.prefix(Self.maxFields).compactMap { PdfText.read(document, $0) ?? (document.resolve($0) as? PdfName)?.value }
        default:
            return []
        }
    }

    private func readOptions(_ value: PdfObject?) -> [FieldOption] {
        guard let array = document.resolve(value) as? PdfArray else { return [] }
        var options: [FieldOption] = []
        for item in array.items.prefix(Self.maxFields) {
            if let pair = document.resolve(item) as? PdfArray, pair.items.count >= 2 {
                let export = PdfText.read(document, pair.items[0]) ?? ""
                options.append(FieldOption(export, PdfText.read(document, pair.items[1]) ?? export))
            } else if let text = PdfText.read(document, item) {
                options.append(FieldOption(text))
            }
        }
        return options
    }

    private func onStateOf(_ widget: PdfDictionary) -> String? {
        guard let ap = document.dict(widget, "AP") else { return nil }
        for key in ["N", "D"] {
            guard let states = document.dict(ap, key) else { continue }
            for entry in states.entries where entry.key != "Off" {
                return entry.key
            }
        }
        return nil
    }
}
