import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FillLayer.cs and FillLayer.Controls.cs. Windows lays real controls over the fields; the
// page here is drawn by the system with every field's appearance, so a text field opens an OverlayField when it is tapped, and
// a check box, a radio button, a button and a signature field are marks a pointer tool hits. A list or a drop-down opens its
// control in the panel.

/// One widget of a field that a person can use on the page.
struct FillSlot {
    let page: Int
    let name: String
    let index: Int
    let kind: FieldKind
    let rect: ViewRect
    let dictionary: PdfDictionary
    let enabled: Bool
    let label: String
    let value: String
    let isOn: Bool
    let missing: Bool
    let multiline: Bool
    let secure: Bool
    let maxLength: Int
    let alignment: Int
    let fontSize: Double
    let onState: String?
    let export: String?
    let noToggleToOff: Bool
    let action: PdfAction?

    // The file is read again after every change, so the widget is told by where it is, not by its dictionary.
    func sameWidget(_ other: FillSlot) -> Bool { page == other.page && name == other.name && index == other.index }
}

@MainActor
final class FillLayer {
    static let fieldPrefix = "forms.field."
    private static let markPrefix = "forms.fill."
    private static let missingColour = OverlayColor(red: 0xD1 / 255.0, green: 0x34 / 255.0, blue: 0x38 / 255.0)

    private let viewer: DocumentViewer
    private let enter: (String, String?) -> Bool
    private let reset: ([String]?) -> Void
    private let sign: (String) -> Void
    private let pick: (String, Int) -> Void

    private var form: PdfForm?
    private var canFill = false
    private var pages: [Int: [FillSlot]] = [:]
    private var openPages = Set<Int>()
    private var focused: (name: String, index: Int)?

    var highlight = true {
        didSet { redrawAll() }
    }

    /// - Parameters:
    ///   - enter: Takes a value typed or tapped into a field and says whether the field kept it.
    ///   - reset: Clears the named fields, or every field for nil; what a Reset button on the page asks for.
    ///   - sign: Opens signing with the named empty signature field chosen.
    ///   - pick: A list or a drop-down was tapped: the panel shows its choices.
    init(_ viewer: DocumentViewer, enter: @escaping (String, String?) -> Bool, reset: @escaping ([String]?) -> Void,
         sign: @escaping (String) -> Void, pick: @escaping (String, Int) -> Void) {
        self.viewer = viewer
        self.enter = enter
        self.reset = reset
        self.sign = sign
        self.pick = pick
    }

    /// Shows the form. Fields being typed in are not disturbed: they are the viewer's, and end by themselves.
    func show(_ form: PdfForm, canFill: Bool) {
        self.form = form
        self.canFill = canFill
        for page in pages.keys { removeMarks(page) }
        pages = [:]
        follow()
    }

    /// Builds the slots of pages that came into view and lets go of those that left.
    func follow() {
        guard form != nil else { return }
        let visible = Set(viewer.visiblePages)
        for page in pages.keys where !visible.contains(page) {
            removeMarks(page)
            pages[page] = nil
        }
        for page in visible { _ = slots(page) }
    }

    func clear() {
        for page in pages.keys { removeMarks(page) }
        viewer.endToolMarks(prefix: Self.markPrefix)
        pages = [:]
        form = nil
        focused = nil
    }

    /// Hands in what is typed in a field that is still open, for a command that reads the file before the field loses the
    /// keyboard.
    func flush() {
        for page in openPages { viewer.overlay(page).finishFields(prefix: Self.fieldPrefix) }
        openPages = []
    }

    /// The widgets of a page in tab order, built the first time the page is asked for.
    func slots(_ page: Int) -> [FillSlot] {
        if let known = pages[page] { return known }
        let made = makeSlots(page)
        pages[page] = made
        draw(page)
        return made
    }

    /// The enabled widget under a point of a page: the smallest that holds it, else the closest within `slop` page points. A
    /// point inside a widget that is off belongs to nothing, so it does not fall to a neighbour.
    func hit(_ page: Int, _ point: ViewPoint, slop: Double) -> FillSlot? {
        let all = slots(page)
        let holding = all.filter { $0.rect.contains(point) }
        if !holding.isEmpty {
            return holding.filter { $0.enabled }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        }
        let near = all.filter { $0.enabled && $0.rect.inflated(slop, slop).contains(point) }
        return near.min { distance($0.rect, point) < distance($1.rect, point) }
    }

    private func distance(_ rect: ViewRect, _ point: ViewPoint) -> Double {
        let dx = max(rect.left - point.x, 0, point.x - rect.right), dy = max(rect.top - point.y, 0, point.y - rect.bottom)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// What a tap on a widget does.
    func activate(_ slot: FillSlot, at point: ViewPoint) {
        guard slot.enabled, canFill else { return }
        switch slot.kind {
        case .text: open(slot, caret: .at(point))
        case .checkBox, .radio: toggle(slot)
        case .pushButton: perform(slot)
        case .signature: sign(slot.name)
        case .comboBox, .listBox: pick(slot.name, slot.index)
        }
    }

    /// Puts the keyboard in the field of a widget, or marks it; false when it has no widget here.
    @discardableResult
    func focus(_ name: String, _ index: Int) -> Bool {
        guard let widget = widgetAt(name, index), let slot = slot(of: widget) else { return false }
        let old = focused.flatMap { widgetAt($0.name, $0.index) }
        focused = (name, index)
        if let old, old.pageIndex != slot.page { draw(old.pageIndex) }
        draw(slot.page)
        if slot.kind == .text && slot.enabled && canFill { open(slot, caret: .end) }
        return true
    }

    /// Does what the widget's button does; for a row of the panel.
    func press(_ name: String, _ index: Int) {
        guard let widget = widgetAt(name, index), let slot = slot(of: widget) else { return }
        activate(slot, at: ViewPoint(slot.rect.x, slot.rect.y))
    }

    private func widgetAt(_ name: String, _ index: Int) -> FormWidget? {
        guard let widgets = form?.find(name)?.widgets, widgets.indices.contains(index), widgets[index].pageIndex >= 0 else { return nil }
        return widgets[index]
    }

    private func slot(of widget: FormWidget) -> FillSlot? {
        slots(widget.pageIndex).first { $0.dictionary === widget.dictionary }
    }

    // MARK: Fields

    private func open(_ slot: FillSlot, caret: FieldCaret) {
        let align: TextAlign = slot.alignment == 1 ? .center : slot.alignment == 2 ? .trailing : .leading
        let id = Self.fieldPrefix + "\(slot.page).\(slot.name).\(slot.index)"
        let field = OverlayField(id, area: slot.rect, text: slot.value, look: OverlayTextLook(size: slot.fontSize, alignment: align),
                                 wraps: slot.multiline, multiline: slot.multiline, label: slot.label, caret: caret,
                                 secure: slot.secure, maxLength: slot.maxLength > 0 ? slot.maxLength : nil) { [weak self] text in
            guard let text, text != slot.value else { return }
            _ = self?.enter(slot.name, text)
        }
        field.onTab = { [weak self, weak field] backwards in
            guard let self, let field else { return }
            let next = self.neighbour(of: slot, backwards ? -1 : 1)
            field.finish()
            if let next {
                self.viewer.reveal(next.page, next.rect)
                self.open(next, caret: .all)
            }
        }
        openPages.insert(slot.page)
        viewer.overlay(slot.page).open(field)
    }

    // A page keeps its own tab order, so the last field of a page hands the keyboard to the first one of the next page that has any.
    private func neighbour(of slot: FillSlot, _ step: Int) -> FillSlot? {
        let own = typable(slot.page)
        guard let at = own.firstIndex(where: { $0.sameWidget(slot) }) else { return nil }
        if own.indices.contains(at + step) { return own[at + step] }
        var page = slot.page + step
        while page >= 0 && page < viewer.pageCount {
            let there = typable(page)
            if let found = step > 0 ? there.first : there.last { return found }
            page += step
        }
        return nil
    }

    private func typable(_ page: Int) -> [FillSlot] {
        (pages[page] ?? makeSlots(page)).filter { $0.kind == .text && $0.enabled }
    }

    private func toggle(_ slot: FillSlot) {
        let value: String?
        switch (slot.kind == .radio, slot.isOn) {
        case (false, true): value = "Off"
        case (false, false): value = slot.onState ?? "Yes"
        case (true, true): value = slot.noToggleToOff ? nil : "Off"
        case (true, false): value = slot.export ?? slot.onState
        }
        if let value { _ = enter(slot.name, value) }
    }

    private func perform(_ slot: FillSlot) {
        guard let action = slot.action, let form else { return }
        if let clear = action as? ResetFormAction {
            let names: [String]?
            if clear.fields.isEmpty {
                names = nil
            } else if clear.flags & 1 == 0 {
                names = clear.fields
            } else {
                var seen = Set<String>()
                names = form.fields.map(\.name).filter { seen.insert($0).inserted && !clear.fields.contains($0) }
            }
            reset(names)
        } else {
            viewer.follow(action)
        }
    }

    // MARK: Slots

    private func makeSlots(_ page: Int) -> [FillSlot] {
        guard let form, page >= 0, page < viewer.pageCount else { return [] }
        let geometry = viewer.geometry(page)
        return form.tabSequence(page).compactMap { widget in
            guard !Self.hidden(widget), let field = widget.field else { return nil }
            let kind = field.kind
            var action: PdfAction?
            if kind == .pushButton {
                action = PdfActions.read(form.document, widget.dictionary["A"])
                guard action is GoToAction || action is UriAction || action is NamedAction || action is ResetFormAction else { return nil }
            }
            if kind == .signature && field.isSigned { return nil }
            let d = geometry.toDisplay(widget.rect)
            let tip = field.tooltip ?? ""
            return FillSlot(page: page, name: field.name, index: field.widgets.firstIndex { $0.dictionary === widget.dictionary } ?? 0,
                            kind: kind, rect: ViewRect(d.x, d.y, d.width, d.height), dictionary: widget.dictionary,
                            enabled: canFill && !field.has(.readOnly), label: tip.isEmpty ? field.name : tip,
                            value: field.value ?? "", isOn: widget.isOn, missing: Self.missing(field),
                            multiline: field.has(.multiline), secure: field.has(.password), maxLength: field.maxLength,
                            alignment: field.alignment, fontSize: Self.fontSize(field, d.height, tall: field.has(.multiline)),
                            onState: widget.onState, export: widget.export, noToggleToOff: field.has(.noToggleToOff), action: action)
        }
    }

    private static func missing(_ field: FormField) -> Bool {
        field.has(.required) && ((field.value?.isEmpty ?? true) || field.value == "Off")
    }

    private static func hidden(_ widget: FormWidget) -> Bool {
        guard let flags = widget.dictionary["F"] as? PdfNumber else { return false }
        return Int(flags.value) & 0b10_0010 != 0
    }

    // Size 0 in the field's /DA means fit the text to the field.
    private static func fontSize(_ field: FormField, _ height: Double, tall: Bool) -> Double {
        let words = (field.defaultAppearance ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        if let tf = words.firstIndex(of: "Tf"), tf > 0, let size = Double(words[tf - 1]), size > 0, size <= 200 { return size }
        return tall ? 12 : min(max(height * 0.7, 4), 12)
    }

    // MARK: Marks

    private func redrawAll() {
        for page in pages.keys { draw(page) }
    }

    private func removeMarks(_ page: Int) {
        viewer.overlay(page).remove(prefix: Self.markPrefix + "\(page).")
    }

    private func draw(_ page: Int) {
        guard let list = pages[page] else { return }
        let overlay = viewer.overlay(page)
        overlay.remove(prefix: Self.markPrefix + "\(page).")
        for (n, slot) in list.enumerated() {
            let isFocus = focused.map { $0.name == slot.name && $0.index == slot.index } ?? false
            guard highlight || slot.missing || isFocus else { continue }
            let shape: OverlayShape = slot.kind == .radio ? .ellipse(slot.rect) : .rect(slot.rect)
            let stroke = isFocus ? OverlayColor.accent : slot.missing ? Self.missingColour : nil
            overlay.set(OverlayItem(Self.markPrefix + "\(page).\(n)", shape,
                                    style: OverlayStyle(stroke: stroke, fill: highlight ? OverlayColor.accent.opacity(0.14) : nil,
                                                        lineWidth: isFocus ? 2.5 : 1.5)))
        }
    }
}

/// The pointer while a form is filled in: a tap on a field does what the field does, and a finger anywhere else scrolls.
@MainActor
final class FillTool: PagePointerTool {
    private weak var model: FormsModel?
    private var pressed: FillSlot?

    init(_ model: FormsModel) {
        self.model = model
    }

    var cursor: PointerCursor? { nil }

    func takes(_ pointer: PagePointer) -> Bool {
        model?.fillHit(pointer.page, pointer.point) != nil
    }

    func press(_ pointer: PagePointer) {
        pressed = model?.fillHit(pointer.page, pointer.point)
    }

    func move(_ pointer: PagePointer) {}

    func release(_ pointer: PagePointer) {
        defer { pressed = nil }
        guard let pressed, let model, let now = model.fillHit(pointer.page, pointer.point), now.sameWidget(pressed) else { return }
        model.fillActivate(now, at: pointer.point)
    }

    func cancel() {
        pressed = nil
    }
}
