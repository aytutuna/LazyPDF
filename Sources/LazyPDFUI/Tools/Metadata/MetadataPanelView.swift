#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of MetadataModel; follows windows/LazyPDF.App/Tools/Metadata/MetadataPanel.xaml.

struct MetadataPanelView: View {
    @Bindable var model: MetadataModel
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case title, author, subject, keywords, language
    }

    var body: some View {
        ToolForm {
            LabelledField(L10n.t("Title")) {
                TextField(L10n.t("Title"), text: $model.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .title)
            }
            LabelledField(L10n.t("Author")) {
                TextField(L10n.t("Author"), text: $model.author)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .author)
            }
            LabelledField(L10n.t("Subject")) {
                TextField(L10n.t("Subject"), text: $model.subject, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .subject)
            }
            LabelledField(L10n.t("Keywords")) {
                TextField(L10n.t("Keywords"), text: $model.keywords)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .keywords)
                ReasonText(L10n.t("Separate them with commas."))
            }
            LabelledField(L10n.t("Created")) {
                Toggle(L10n.t("Created"), isOn: hasCreated)
                    .labelsHidden()
                if model.created != nil {
                    DatePicker(L10n.t("Created"), selection: createdDay, displayedComponents: .date)
                        .labelsHidden()
                }
                ReasonText(model.modifiedText)
                Toggle(L10n.t("Update the changed date"), isOn: $model.touchModified)
                if !model.makerText.isEmpty { ReasonText(model.makerText) }
            }

            SectionHeading(L10n.t("When it opens"))
            LabelledField(L10n.t("Show beside the page")) {
                choice(L10n.t("Show beside the page"), $model.modeIndex, MetadataEdit.modes.map(MetadataEdit.modeName))
            }
            LabelledField(L10n.t("Page layout")) {
                choice(L10n.t("Page layout"), $model.layoutIndex, MetadataEdit.layouts.map(MetadataEdit.layoutName))
            }
            LabelledField(L10n.t("Language")) {
                TextField(L10n.t("Language"), text: $model.language)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .language)
                ReasonText(L10n.t("A code such as en-US or tr-TR."))
            }
            Toggle(L10n.t("Title in the title bar"), isOn: $model.displayDocTitle)
            Toggle(L10n.t("Hide the toolbar"), isOn: $model.hideToolbar)
            Toggle(L10n.t("Hide the menu bar"), isOn: $model.hideMenubar)
            Toggle(L10n.t("Hide window controls"), isOn: $model.hideWindowUI)
            Toggle(L10n.t("Size window to page"), isOn: $model.fitWindow)
            Toggle(L10n.t("Centre the window"), isOn: $model.centerWindow)
            Toggle(L10n.t("Read right to left"), isOn: $model.rightToLeft)

            SectionHeading(L10n.t("When it prints"))
            Toggle(L10n.t("Print at actual size"), isOn: $model.printScalingNone)
            LabelledField(L10n.t("Sides")) {
                choice(L10n.t("Sides"), $model.sidesIndex, MetadataEdit.sides.map(MetadataEdit.sidesName))
            }
            LabelledField(L10n.t("Copies")) {
                choice(L10n.t("Copies"), $model.copiesIndex, [L10n.t("Printer default"), "2", "3", "4", "5"])
            }
        }
        // Leaving a text field puts what was typed into the file, unless a signed file has to be asked first.
        .onChange(of: focus) { old, _ in
            if old != nil && !model.asksFirst { _ = model.handIn() }
        }
    }

    private func choice(_ label: String, _ selection: Binding<Int>, _ names: [String]) -> some View {
        Picker(label, selection: selection) {
            ForEach(names.indices, id: \.self) { Text(names[$0]).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasCreated: Binding<Bool> {
        Binding(get: { model.created != nil }, set: { model.created = $0 ? Calendar.current.startOfDay(for: Date()) : nil })
    }

    private var createdDay: Binding<Date> {
        Binding(get: { model.created ?? Date() }, set: { model.created = $0 })
    }
}
#endif
