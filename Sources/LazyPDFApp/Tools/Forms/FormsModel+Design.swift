import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FormsPanel.Design.cs: editing the fields. The field the pointer tool selected, its
// properties in the card, drawing, moving and resizing, the tab order of the page and the fields the detector finds.

/// The boxes of the card that write a property when they are left.
public enum CardProperty {
    case name, hint, length, choices, caption, start, export, size, target
}

extension FormsModel {
    public var drawHint: String {
        newKind == .radio ? L10n.t("Drag on the page to draw it. With a radio group selected the button joins it.")
            : L10n.t("Drag on the page to draw a field. Click a field to change it.")
    }

    /// `ordinal` tells apart fields that share a name; most names have one.
    public func select(_ name: String?, _ index: Int, _ ordinal: Int = 0) {
        guard !isWorking else { return }
        commitCard()
        selected = name
        selectedIndex = index
        selectedOrdinal = ordinal
        if let radio = selectedField(form), radio.kind == .radio { groupName = radio.name }
        showDesign(form)
    }

    func selectedField(_ form: PdfForm) -> FormField? {
        guard let selected else { return nil }
        let same = form.findAll(selected)
        return same.indices.contains(selectedOrdinal) ? same[selectedOrdinal] : nil
    }

    func selectedBox() -> (page: Int, box: ViewRect)? {
        guard let widget = selectedField(form).flatMap({ $0.widgets.indices.contains(selectedIndex) ? $0.widgets[selectedIndex] : nil }),
              widget.pageIndex >= 0 else { return nil }
        return (widget.pageIndex, boxOf(widget))
    }

    /// The field under a point of a page; the smallest wins, so a check box on a large text field can be picked. With `near`, a
    /// point a little outside every box finds the closest one, so a finger can pick a small field; with `exact` only a check box or a
    /// radio button is found that way.
    func widgetAt(_ page: Int, _ point: ViewPoint, near allowed: Bool = false, exact: Bool = false) -> (name: String, index: Int, ordinal: Int, box: ViewRect)? {
        var inside: (name: String, index: Int, ordinal: Int, box: ViewRect)?
        var near: (name: String, index: Int, ordinal: Int, box: ViewRect)?
        let reach = slop(page)
        var seen: [String: Int] = [:]
        for field in form.fields {
            let ordinal = seen[field.name, default: 0]
            seen[field.name] = ordinal + 1
            for (i, widget) in field.widgets.enumerated() where widget.pageIndex == page {
                let box = boxOf(widget)
                let candidate = (field.name, i, ordinal, box)
                if box.contains(point) {
                    if inside == nil || box.width * box.height < inside!.box.width * inside!.box.height { inside = candidate }
                } else if allowed && (!exact || field.kind == .checkBox || field.kind == .radio) && box.inflated(reach, reach).contains(point) {
                    if near == nil || box.width * box.height < near!.box.width * near!.box.height { near = candidate }
                }
            }
        }
        return inside ?? near
    }

    func draw(_ page: Int, _ box: ViewRect) {
        guard let kind = newKind else { return }
        let rect = userRect(page, box)
        let chosen = selected
        let group = groupName
        let ordinal = selectedOrdinal
        let added = edit(L10n.t("Add form field")) { form -> (name: String, widget: Int) in
            let same = chosen.map { form.findAll($0) } ?? []
            return try FormEdits.add(form, kind, page, rect, same.indices.contains(ordinal) ? same[ordinal] : nil, group: group)
        }
        if let added { select(added.name, added.widget, added.name == chosen ? ordinal : 0) }
    }

    func reshape(_ page: Int, _ box: ViewRect) {
        let rect = userRect(page, box)
        let index = selectedIndex
        _ = changeField(L10n.t("Move form field")) { form, field in try form.resize(field.widgets[index], rect) }
    }

    private func boxOf(_ widget: FormWidget) -> ViewRect {
        FieldFrames.box(viewer!.geometry(widget.pageIndex).toDisplay(widget.rect))
    }

    private func userRect(_ page: Int, _ box: ViewRect) -> PdfRect {
        let size = viewer!.pageSize(page)
        let x = min(max(box.x, 0), max(0, size.width - box.width))
        let y = min(max(box.y, 0), max(0, size.height - box.height))
        return viewer!.geometry(page).toUser(DisplayRect(x, y, min(box.width, size.width), min(box.height, size.height)))
    }

    func showDesign(_ form: PdfForm) {
        frames?.show(form, selected: selected, index: selectedIndex, ordinal: selectedOrdinal,
                     proposals: found.filter(\.isChecked).map(\.proposal))
        showCard(form)
        showTabOrder()
    }

    func showCard(_ form: PdfForm) {
        guard let field = selectedField(form) else {
            cardKind = nil
            return
        }
        cardKind = field.kind
        cardFlags = field.flags
        nameDraft = field.name
        hintDraft = field.tooltip ?? ""
        lengthDraft = field.maxLength > 0 ? String(field.maxLength) : ""
        choicesDraft = FormEdits.formatOptions(field.options)
        startDraft = field.defaultValue ?? ""
        captionDraft = field.kind == .pushButton ? FormEdits.caption(of: form, field) : ""
        showStyle(form, field)
    }

    func showTabOrder() {
        guard let tab, let viewer, tab.document.pages.count > 0 else { return }
        let page = min(max(viewer.pageIndex, 0), tab.document.pages.count - 1)
        tabOrder = FormChoices.tabOrders.first { $0.order == form.getTabOrder(page) }?.order ?? .annotations
    }

    public func setTabOrder(_ order: TabOrder) {
        guard let viewer else { return }
        let page = viewer.pageIndex
        if edit(L10n.t("Change tab order"), { form -> Bool in form.setTabOrder(page, order); return true }) == nil { showTabOrder() }
    }

    /// Writes a box of the card when it is left or Return is pressed.
    public func commit(_ property: CardProperty) {
        guard let field = selectedField(form) else { return }
        var done = true
        switch property {
        case .name:
            done = rename(field, nameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        case .hint:
            let typed = hintDraft
            if typed != (field.tooltip ?? "") { done = changeField(L10n.t("Change field hint")) { form, f in form.setTooltip(f, typed) } }
        case .length:
            done = commitLength(field)
        case .choices:
            let typed = choicesDraft
            if typed != FormEdits.formatOptions(field.options) {
                done = changeField(L10n.t("Change choices")) { form, f in try form.setOptions(f, FormEdits.parseOptions(typed)) }
            }
        case .caption:
            let typed = captionDraft
            if typed != FormEdits.caption(of: form, field) {
                done = changeField(L10n.t("Change button caption")) { form, f in try FormEdits.setCaption(form, f, typed) }
            }
        case .start:
            let typed = startDraft
            if typed != (field.defaultValue ?? "") {
                done = changeField(L10n.t("Change starting value")) { form, f in form.setDefaultValue(f, typed.isEmpty ? nil : typed) }
            }
        case .export:
            done = commitExport(field)
        case .size:
            done = commitSize(field)
        case .target:
            done = commitTarget(field)
        }
        if !done { showCard(form) }
    }

    private func commitLength(_ field: FormField) -> Bool {
        let typed = lengthDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty && (!typed.allSatisfy { $0.isASCII && $0.isNumber } || Int(typed) == nil) {
            host?.showProblem(Problem(L10n.t("Longest text not a number"), L10n.t("Type a whole number, or leave it empty for no limit.")))
            return false
        }
        let length = typed.isEmpty ? 0 : Int(typed)!
        if length == field.maxLength { return true }
        return changeField(L10n.t("Change longest text")) { form, f in try form.setMaxLength(f, length) }
    }

    private func rename(_ field: FormField, _ name: String) -> Bool {
        if name == field.name { return true }
        if name.isEmpty || name.hasSuffix(".") {
            host?.showProblem(Problem(L10n.t("Field not changed"), FormText.badName))
            return false
        }
        guard changeField(L10n.t("Rename field"), { form, f in try form.rename(f, name) }) else { return false }
        selected = name
        selectedOrdinal = form.findAll(name).count - 1
        if let radio = selectedField(form), radio.kind == .radio { groupName = radio.name }
        showDesign(form)
        return true
    }

    /// A check box of the card, or the flag a kind has: required, read only, several lines, hidden text, several choices, typing
    /// in a list.
    public func setFlag(_ flag: FieldFlags, _ on: Bool) {
        guard selected != nil else { return }
        let label: String
        switch flag {
        case .required: label = L10n.t("Change required")
        case .readOnly: label = L10n.t("Change read only")
        case .multiline: label = L10n.t("Change several lines")
        case .multiSelect: label = L10n.t("Change several choices")
        case .edit: label = L10n.t("Change typing in the list")
        default: label = L10n.t("Change hidden text")
        }
        if !changeField(label, { form, f in try form.setFlag(f, flag, on) }) { showCard(form) }
    }

    public func deleteSelected() {
        guard selected != nil else { return }
        let index = selectedIndex
        // A radio button of a group of several goes alone; the last one takes the field with it.
        let gone = changeField(L10n.t("Delete form field")) { form, field in
            if field.widgets.count > 1 { try form.remove(field.widgets[index]) } else { try form.remove(field) }
        }
        if gone { select(nil, 0, 0) }
    }

    func changeField(_ label: String, _ change: @escaping (PdfForm, FormField) throws -> Void) -> Bool {
        guard let name = selected else { return false }
        let ordinal = selectedOrdinal
        return edit(label) { form -> Bool in
            let same = form.findAll(name)
            guard same.indices.contains(ordinal) else { throw InvalidOperationException(FormText.notAField) }
            try change(form, same[ordinal])
            return true
        } ?? false
    }

    public func findFields() async {
        guard handIn(), let tab, let host else { return }
        await tab.whenDrawn()
        let bytes = tab.session.current
        let password = tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        let renderer = tab.renderer
        var proposals: [FieldProposal]?
        do {
            try await host.runBusy(L10n.t("Looking for fields")) { token in
                proposals = try await FormEdits.detect(bytes, password: password, certificate: certificate, renderer: renderer, token: token)
            }
        } catch {
            host.showProblem(FormEdits.problem(of: error))
            return
        }
        guard let proposals, self.tab === tab else { return }
        found = proposals.map { FoundRow(proposal: $0) }
        foundText = proposals.isEmpty ? L10n.t("No blanks found.")
            : L10n.plural(proposals.count, one: "{0} field found.", other: "{0} fields found.")
                + (proposals.contains { $0.fromPixels } ? " " + L10n.t("Fields on scanned pages are guesses. Check each one.") : "")
        foundShown = true
        showDesign(form)
    }

    // A page that went with an undo takes its proposals with it.
    func pruneFound(_ form: PdfForm) {
        let pages = form.document.pages.count
        let kept = found.filter { $0.proposal.pageIndex < pages }
        if kept.count == found.count { return }
        found = kept
        if kept.isEmpty {
            foundShown = false
        } else {
            foundText = L10n.plural(kept.count, one: "{0} field found.", other: "{0} fields found.")
        }
    }

    /// Writes the box of the card that still has the keyboard.
    func commitCard() {
        guard let property = cardFocus else { return }
        cardFocus = nil
        commit(property)
    }

    public func setFound(_ id: String, _ checked: Bool) {
        guard let at = found.firstIndex(where: { $0.id == id }) else { return }
        found[at].isChecked = checked
        showDesign(form)
    }

    public func addFound() {
        let chosen = found.filter(\.isChecked).map(\.proposal)
        guard !chosen.isEmpty, let added = edit(L10n.t("Add form fields"), { form in try FormEdits.addFound(form, chosen) }), added > 0 else { return }
        found = []
        foundShown = false
        showDesign(form)
        host?.setStatus(L10n.plural(chosen.count, one: "Added {0} field.", other: "Added {0} fields."))
    }
}
