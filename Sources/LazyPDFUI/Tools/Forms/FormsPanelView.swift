#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of FormsModel; follows windows/LazyPDF.App/Tools/Forms/FormsPanel.xaml. Filling and editing share the list of fields; the
// list is also how a person reaches a field by VoiceOver, since the marks on the page are not in the accessibility tree.

struct FormsPanelView: View {
    @Bindable var model: FormsModel

    var body: some View {
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
                    Text(row.isRequired ? row.name + " *" : row.name).font(.body.weight(.semibold))
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
            Toggle(row.name, isOn: Binding(get: { row.isOn }, set: { _ in model.toggleRow(row) }))
                .disabled(!row.canFill)
        case .radio, .comboBox:
            Picker(row.name, selection: Binding(get: { row.value }, set: { model.chooseRow(row, $0) })) {
                if row.kind == .comboBox { Text(L10n.t("None")).tag("") }
                ForEach(row.options, id: \.export) { Text($0.display).tag($0.export) }
            }
            .disabled(!row.canFill)
        case .listBox:
            if model.activeRow == row.id {
                ForEach(row.options, id: \.export) { option in
                    Toggle(option.display, isOn: Binding(get: { row.selected.contains(option.export) || row.selected.contains(option.display) },
                                                         set: { change(option, $0) }))
                        .disabled(!row.canFill)
                }
            }
        case .signature:
            if row.canFill {
                Button(L10n.t("Click to sign")) { model.pressRow(row) }.frame(minHeight: 44)
            }
        case .pushButton:
            if row.canFill {
                Button(row.name) { model.pressRow(row) }.frame(minHeight: 44)
            }
        case .text:
            EmptyView()
        }
    }

    private func change(_ option: FieldOption, _ on: Bool) {
        var picked = Set(row.options.filter { row.selected.contains($0.export) || row.selected.contains($0.display) }.map(\.export))
        if on { picked.insert(option.export) } else { picked.remove(option.export) }
        model.chooseRow(row, many: row.options.map(\.export).filter { picked.contains($0) })
    }
}
#endif
