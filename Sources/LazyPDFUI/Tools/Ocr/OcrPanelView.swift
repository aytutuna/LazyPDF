#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of OcrModel; follows windows/LazyPDF.App/Tools/Ocr/OcrPanel.xaml.

struct OcrPanelView: View {
    @Bindable var model: OcrModel

    var body: some View {
        ToolForm {
            LabelledField(L10n.t("Language")) {
                Picker(L10n.t("Language"), selection: $model.language) {
                    ForEach(model.languages, id: \.tag) { Text($0.name).tag($0.tag) }
                }
                .labelsHidden()
                .disabled(model.languages.isEmpty)
                if !model.languageNote.isEmpty { ReasonText(model.languageNote) }
            }

            LabelledField(L10n.t("Pages")) {
                ReasonText(model.pagesSummary)
                    .accessibilityAddTraits(.updatesFrequently)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in pageRow(row) }
                    }
                }
                .frame(maxHeight: 190)
                .accessibilityLabel(L10n.t("Pages to read"))
            }

            LabelledField(L10n.t("Pages that are already searchable")) {
                Picker(L10n.t("Pages that are already searchable"), selection: Binding(get: { model.replacing }, set: { model.setReplacing($0) })) {
                    Text(L10n.t("Keep")).tag(false).accessibilityLabel(L10n.t("Keep their text"))
                    Text(L10n.t("Replace")).tag(true).accessibilityLabel(L10n.t("Replace their text"))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Button(role: .destructive) {
                model.removeLayers()
            } label: {
                Label(L10n.t("Remove text layer"), systemImage: "trash")
                    .frame(minHeight: 28)
            }
            .disabled(!model.canRemove)
            .help(L10n.t("Take the recognized text off the chosen pages"))
            if !model.removeNote.isEmpty { ReasonText(model.removeNote) }

            SectionHeading(L10n.t("Correct a word"))
            Toggle(L10n.t("Show words on the page"), isOn: Binding(get: { model.showWords }, set: { model.setShowWords($0) }))
            if model.words.isEmpty {
                if model.showWords { ReasonText(L10n.t("Click a word on the page or choose one below.")) }
            } else {
                wordList
                if let picked = model.picked {
                    ReasonText(L10n.t("Page {0}", picked.page + 1))
                    ReasonText(L10n.t("Leave it empty to remove the word."))
                }
            }
        }
        .disabled(model.isRunning)
    }

    private func pageRow(_ row: PageRow) -> some View {
        let on = model.selected.contains(row.page)
        return Button {
            model.setSelected(row.page, !on)
        } label: {
            HStack {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                Text(row.label)
                Spacer()
                Text(row.kindText).font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.spoken)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // The words of the page in view, for whoever cannot point at them; choosing one opens it for correction on the page.
    private var wordList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.words, id: \.index) { word in
                    let on = model.picked?.index == word.index
                    Button {
                        model.pickFromList(word)
                    } label: {
                        Text(word.text)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .background(on ? Color.accentColor.opacity(0.2) : Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(word.text)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .frame(maxHeight: 160)
        .accessibilityLabel(L10n.t("Words on this page"))
    }
}
#endif
