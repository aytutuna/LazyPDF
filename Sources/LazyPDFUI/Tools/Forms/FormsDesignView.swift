#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The editing half of the forms panel; follows the DesignPane of windows/LazyPDF.App/Tools/Forms/FormsPanel.xaml: the kind of field
// to draw, the card of the selected field, the tab order of the page and the blanks the detector found.

struct FormsDesignView: View {
    @Bindable var model: FormsModel
    @FocusState private var focus: CardProperty?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabelledField(L10n.t("New field")) {
                Picker(L10n.t("New field"), selection: $model.newKind) {
                    ForEach(FormChoices.kinds, id: \.text) { Text($0.text).tag($0.kind) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.newKind == .radio {
                LabelledField(L10n.t("Group name")) {
                    TextField(L10n.t("Radio group name"), text: $model.groupName)
                        .textFieldStyle(.roundedBorder)
                    ReasonText(L10n.t("Buttons with one name are one group. Leave it empty to join the selected group or start a new one."))
                }
            }
            ReasonText(model.drawHint)

            if let kind = model.cardKind { card(kind) }

            LabelledField(L10n.t("Tab order on this page")) {
                Picker(L10n.t("Tab order on this page"), selection: Binding(get: { model.tabOrder }, set: { model.setTabOrder($0) })) {
                    ForEach(FormChoices.tabOrders, id: \.text) { Text($0.text).tag($0.order) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await model.findFields() }
            } label: {
                Label(L10n.t("Find fields"), systemImage: "magnifyingglass").frame(minHeight: 44)
            }
            .accessibilityLabel(L10n.t("Find fields in the file"))
            if model.foundShown { found }
        }
        .disabled(!model.canEdit)
        .onChange(of: focus) { old, new in
            model.cardFocus = new
            if let old { model.commit(old) }
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReasonText(model.foundText)
            ForEach(model.found) { row in
                Toggle(row.text, isOn: Binding(get: { row.isChecked }, set: { model.setFound(row.id, $0) }))
            }
            if !model.found.isEmpty {
                Button {
                    model.addFound()
                } label: {
                    Label(L10n.t("Add checked fields"), systemImage: "plus").frame(minHeight: 44)
                }
            }
        }
    }

    private func card(_ kind: FieldKind) -> some View {
        let text = kind == .text
        let choice = kind == .comboBox || kind == .listBox
        let styled = kind == .text || choice || kind == .pushButton
        return VStack(alignment: .leading, spacing: 8) {
            box(L10n.t("Name"), L10n.t("Field name"), $model.nameDraft, .name)
            box(L10n.t("Hint"), L10n.t("Field hint"), $model.hintDraft, .hint)
            flag(L10n.t("Required"), .required)
            flag(L10n.t("Read only"), .readOnly)
            if text {
                flag(L10n.t("Several lines"), .multiline)
                flag(L10n.t("Hide the text"), .password)
            }
            if kind == .listBox { flag(L10n.t("Several choices"), .multiSelect) }
            if kind == .comboBox { flag(L10n.t("Typing allowed"), .edit) }
            if kind == .pushButton { box(L10n.t("Caption"), L10n.t("Button caption"), $model.captionDraft, .caption) }
            if text { box(L10n.t("Longest text"), L10n.t("Longest text"), $model.lengthDraft, .length, number: true) }
            if choice {
                LabelledField(L10n.t("Choices")) {
                    TextField(L10n.t("Choices"), text: $model.choicesDraft, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .choices)
                    ReasonText(L10n.t("One choice per line."))
                }
            }
            if text || choice { box(L10n.t("Starting value"), L10n.t("Starting value"), $model.startDraft, .start) }
            if kind == .checkBox || kind == .radio {
                box(L10n.t("Export value"), L10n.t("Export value"), $model.exportDraft, .export)
                ReasonText(L10n.t("The value saved when this button is chosen."))
            }
            if styled {
                LabelledField(L10n.t("Font")) {
                    Picker(L10n.t("Font"), selection: Binding(get: { model.fontName ?? "" }, set: { model.setFont($0) })) {
                        ForEach(FormChoices.fonts, id: \.name) { Text($0.text).tag($0.name) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                box(L10n.t("Text size"), L10n.t("Text size"), $model.sizeDraft, .size, number: true)
                ReasonText(L10n.t("Leave it empty to fit the text to the field."))
            }
            if kind != .signature {
                LabelledField(L10n.t("Text color")) {
                    Picker(L10n.t("Text color"), selection: Binding(get: { model.colourIndex ?? -1 }, set: { model.setColour($0) })) {
                        ForEach(Array(FormChoices.colours.enumerated()), id: \.offset) { Text($0.element.text).tag($0.offset) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if kind == .pushButton { action }
            Button(role: .destructive) {
                model.deleteSelected()
            } label: {
                Label(L10n.t("Delete field"), systemImage: "trash").frame(minHeight: 44)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var action: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabelledField(L10n.t("Button action")) {
                Picker(L10n.t("Button action"), selection: Binding(get: { model.actionKind }, set: { model.chooseAction($0) })) {
                    ForEach(FormChoices.actions, id: \.text) { Text($0.text).tag($0.kind) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.needsTarget {
                box(model.targetLabel, L10n.t("Address or field name"), $model.targetDraft, .target)
            }
        }
    }

    private func box(_ title: String, _ label: String, _ text: Binding<String>, _ property: CardProperty, number: Bool = false) -> some View {
        LabelledField(title) {
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(number ? .decimalPad : .default)
                #endif
                .focused($focus, equals: property)
                .onSubmit { model.commit(property) }
        }
    }

    private func flag(_ title: String, _ flag: FieldFlags) -> some View {
        Toggle(title, isOn: Binding(get: { model.cardFlags.contains(flag) }, set: { model.setFlag(flag, $0) }))
    }
}
#endif
