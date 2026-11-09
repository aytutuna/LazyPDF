#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of FormsModel; follows windows/LazyPDF.App/Tools/Forms/FormsPanel.xaml. Filling and editing share the list of fields; the
// list is also how a person reaches a field by VoiceOver, since the marks on the page are not in the accessibility tree.

struct FormsPanelView: View {
    @Bindable var model: FormsModel

    var body: some View {
        ScrollViewReader { proxy in
            panel
                .onChange(of: model.activeRow) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
        }
    }

    // Nothing in the panel is reached while an edit runs off the main actor on the document.
    private var panel: some View {
        ToolForm {
            Picker(L10n.t("Fill in the form"), selection: Binding(get: { model.designing }, set: { model.setDesigning($0) })) {
                Text(L10n.t("Fill in")).tag(false)
                Text(L10n.t("Edit fields")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ReasonText(model.designing ? L10n.t("Tap a field to change it. Choose a kind below to draw a new one.")
                : L10n.t("Tap a field on the page to fill it in, or choose it from the list."))
            Text(model.summary)
            if let note = model.note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.rows.isEmpty {
                FieldLabel(L10n.t("Fields"))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.rows) { FieldRowView(model: model, row: $0) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.t("Fields"))
            }

            if model.designing {
                FormsDesignView(model: model)
            } else {
                fillPane
            }
            dataPane
        }
        .disabled(model.isWorking)
    }

    private var fillPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.t("Highlight fields"), isOn: Binding(get: { model.highlight }, set: { model.setHighlight($0) }))
            ReasonText(L10n.t("A red outline marks a required field that is empty."))
            Button {
                Task { await model.resetForm() }
            } label: {
                Label(L10n.t("Reset form"), systemImage: "arrow.counterclockwise")
                    .frame(minHeight: 44)
            }
            .disabled(!model.canFillForm || model.isWorking)
        }
    }

    private var dataPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L10n.t("Form data"))
            Picker(L10n.t("Form data"), selection: $model.dataFormat) {
                ForEach(DataFormat.allCases, id: \.self) { Text($0.fileExtension.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Button {
                    Task { await model.importData() }
                } label: {
                    Label(L10n.t("Import"), systemImage: "square.and.arrow.down").frame(minHeight: 44)
                }
                .accessibilityLabel(L10n.t("Import form data"))
                Button {
                    Task { await model.exportData() }
                } label: {
                    Label(L10n.t("Export"), systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }
                .accessibilityLabel(L10n.t("Export form data"))
            }
            .disabled(!model.canFillForm || model.isWorking)
            ReasonText(L10n.t("FDF, XFDF, CSV and JSON files."))
        }
    }
}

/// A field in the list: its name and kind, and the control that sets it without the page.
private struct FieldRowView: View {
    let model: FormsModel
    let row: FieldRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.focusRow(row)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.isRequired ? row.label + " *" : row.label).font(.body.weight(.semibold))
                    if !row.hint.isEmpty { Text(row.name).font(.caption).foregroundStyle(.secondary) }
                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    if !shownValue.isEmpty { Text(shownValue).font(.caption).lineLimit(2) }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.summary)
            .accessibilityValue(shownValue)
            if !model.designing { control }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(model.activeRow == row.id ? Color.accentColor.opacity(0.15) : Color.clear))
        .id(row.id)
    }

    private var shownValue: String {
        switch row.kind {
        case .text: return row.isSecret ? String(repeating: "\u{2022}", count: min(row.value.count, 12)) : row.value
        case .comboBox, .radio: return row.value
        case .listBox: return row.selected.joined(separator: ", ")
        default: return ""
        }
    }

    @ViewBuilder private var control: some View {
        switch row.kind {
        case .checkBox:
            Toggle(row.label, isOn: Binding(get: { row.isOn }, set: { _ in model.toggleRow(row) }))
                .disabled(!row.canFill)
        case .radio:
            Picker(row.label, selection: Binding(get: { row.value }, set: { model.chooseRow(row, $0) })) {
                ForEach(row.options, id: \.export) { Text($0.display).tag($0.export) }
            }
            .disabled(!row.canFill)
        case .comboBox:
            if row.isEditable { TextRow(model: model, row: row) }
            Picker(row.label, selection: Binding(get: { row.value }, set: { model.chooseRow(row, $0) })) {
                Text(L10n.t("None")).tag("")
                if !row.value.isEmpty && !row.options.contains(where: { $0.export == row.value }) { Text(row.value).tag(row.value) }
                ForEach(row.options, id: \.export) { Text($0.display).tag($0.export) }
            }
            .disabled(!row.canFill)
        case .listBox:
            if model.activeRow == row.id { choices }
        case .signature:
            if row.canFill {
                Button(L10n.t("Click to sign")) { model.pressRow(row) }.frame(minHeight: 44)
            }
        case .pushButton:
            if row.canFill {
                Button(row.label) { model.pressRow(row) }.frame(minHeight: 44)
            }
        case .text:
            TextRow(model: model, row: row)
        }
    }

    // A list that takes one choice shows them as one pick; a second toggle on would only be undone by the engine.
    @ViewBuilder private var choices: some View {
        if row.multiSelect {
            ForEach(row.options, id: \.export) { option in
                Toggle(option.display, isOn: Binding(get: { row.chosen.contains(option.export) }, set: { model.setChoice(row, option, $0) }))
                    .disabled(!row.canFill)
            }
        } else {
            Picker(row.label, selection: Binding(get: { row.chosen.first ?? "" }, set: { export in
                if let option = row.options.first(where: { $0.export == export }) { model.setChoice(row, option, true) }
            })) {
                ForEach(row.options, id: \.export) { Text($0.display).tag($0.export) }
            }
            .pickerStyle(.inline)
            .disabled(!row.canFill)
        }
    }
}

/// A text box in a row, for a value typed without the page: the large sheet covers the field on the page and its keyboard. It is
/// written when it is left or Return is pressed.
private struct TextRow: View {
    let model: FormsModel
    let row: FieldRow
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        field
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .frame(minHeight: 44)
            .disabled(!row.canFill)
            .onAppear { draft = row.value }
            .onChange(of: row.value) { _, value in
                if !focused { draft = value }
            }
            .onChange(of: focused) { _, now in
                if !now { write() }
            }
            .onSubmit { write() }
            .onDisappear { write() }
    }

    @ViewBuilder private var field: some View {
        if row.isSecret {
            SecureField(row.label, text: $draft)
        } else {
            TextField(row.label, text: $draft)
        }
    }

    private func write() {
        model.typeRow(row, draft)
    }
}
#endif
