import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FormsPanel.Style.cs: the card rows that set how a field looks and what a button does:
// export value, font, size, colour and action.

extension FormsModel {
    func showStyle(_ form: PdfForm, _ field: FormField) {
        let button = field.kind == .checkBox || field.kind == .radio
        exportDraft = button && field.widgets.indices.contains(selectedIndex) ? field.widgets[selectedIndex].export ?? "" : ""
        let look = form.getTextLook(field)
        fontName = FormChoices.fonts.first { $0.name == look.font }?.name
        sizeDraft = look.size > 0 ? Self.sizeText(look.size) : ""
        colourIndex = FormChoices.colours.firstIndex { FormEdits.sameColour($0.rgb, look.color) }
        if field.kind == .pushButton {
            let action = form.getButtonAction(field)
            actionKind = action.kind
            targetDraft = action.target ?? ""
        }
    }

    // Up to two decimals, no trailing zeros, whatever the language of the system.
    static func sizeText(_ size: Double) -> String {
        var text = String(format: "%.2f", size)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    public func setFont(_ name: String) {
        guard let field = selectedField(form) else { return }
        fontName = name
        if name != form.getTextLook(field).font && !changeField(L10n.t("Change font"), { form, f in try form.setFont(f, name) }) { showCard(form) }
    }

    public func setColour(_ index: Int) {
        let colours = FormChoices.colours
        guard let field = selectedField(form), colours.indices.contains(index) else { return }
        colourIndex = index
        let rgb = colours[index].rgb
        if !FormEdits.sameColour(rgb, form.getTextLook(field).color) && !changeField(L10n.t("Change text colour"), { form, f in try form.setTextColor(f, rgb) }) {
            showCard(form)
        }
    }

    // A kind that needs an address or a field waits for it to be typed.
    public func chooseAction(_ kind: ButtonActionKind) {
        let previous = actionKind
        actionKind = kind
        guard let field = selectedField(form) else { return }
        // An address is not a field name, so it does not carry over from one to the other.
        if !FormChoices.needsTarget(previous) || FormChoices.isFieldAction(previous) != FormChoices.isFieldAction(kind) { targetDraft = "" }
        if kind != form.getButtonAction(field).kind && (!FormChoices.needsTarget(kind) || !targetDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            _ = setAction(kind)
        }
    }

    public var targetLabel: String {
        FormChoices.isFieldAction(actionKind) ? L10n.t("Field name") : L10n.t("Address")
    }

    public var needsTarget: Bool { FormChoices.needsTarget(actionKind) }

    func commitExport(_ field: FormField) -> Bool {
        let typed = exportDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = selectedIndex
        if typed == (field.widgets.indices.contains(index) ? field.widgets[index].export ?? "" : "") { return true }
        return changeField(L10n.t("Change export value")) { form, f in try form.setExportValue(f.widgets[index], typed) }
    }

    func commitSize(_ field: FormField) -> Bool {
        let typed = sizeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var size = 0.0
        if !typed.isEmpty {
            guard let parsed = Double(typed), parsed >= 0, parsed <= 200 else {
                host?.showProblem(Problem(L10n.t("Text size not accepted"), L10n.t("Type a number from 0 to 200, or leave it empty to fit the text to the field.")))
                return false
            }
            size = parsed
        }
        if size == form.getTextLook(field).size { return true }
        return changeField(L10n.t("Change text size")) { form, f in try form.setFontSize(f, size) }
    }

    func commitTarget(_ field: FormField) -> Bool {
        let current = form.getButtonAction(field)
        let typed = targetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FormChoices.needsTarget(actionKind), !typed.isEmpty else { return true }
        return (actionKind == current.kind && typed == current.target) || setAction(actionKind)
    }

    private func setAction(_ kind: ButtonActionKind) -> Bool {
        var target = targetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .openLink || kind == .submit {
            guard let address = FormEdits.address(of: target) else {
                host?.showProblem(Problem(L10n.t("Address not accepted"), L10n.t("Type a web address such as https://example.com.")))
                return false
            }
            target = address
        }
        let done = changeField(L10n.t("Change button action")) { [target] form, f in try form.setButtonAction(f, ButtonAction(kind, target)) }
        if !done { showCard(form) }
        return done
    }
}
