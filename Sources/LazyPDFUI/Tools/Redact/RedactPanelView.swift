#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of RedactModel; follows windows/LazyPDF.App/Tools/Redact/RedactPanel.xaml. On a phone the sentence at the top says
// what to do on the page, since the page stays live above the sheet.

struct RedactPanelView: View {
    @Bindable var model: RedactModel

    var body: some View {
        ToolForm {
            if model.restricted {
                Label(L10n.t("This file does not allow changes. It cannot be redacted."), systemImage: "lock")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ReasonText(L10n.t("Draw boxes on the page, select text or search, then redact to a new file."))
                if let result = model.result { ResultCard(result: result) }
                markSection
                findSection
                marksList
                coverSection
                optionSection
                Label(L10n.t("The result opens as a new file. This file is not changed."), systemImage: "doc.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var markSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L10n.t("Mark"))
            Toggle(L10n.t("Draw boxes on the page"), isOn: Binding(get: { model.drawing }, set: { model.setDrawing($0) }))
            Button {
                Task { await model.markSelection() }
            } label: {
                Label(L10n.t("Mark selected text"), systemImage: "plus")
                    .frame(minHeight: 44)
            }
            .disabled(!model.hasSelection)
            if !model.hasSelection { ReasonText(L10n.t("Select text on the page first.")) }
        }
    }

    private var findSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L10n.t("Find"))
            LabelledField(L10n.t("Word or phrase")) {
                TextField(L10n.t("Word or phrase"), text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await model.markWords() } }
            }
            Toggle(L10n.t("Match case"), isOn: $model.matchCase)
            Toggle(L10n.t("Whole word"), isOn: $model.wholeWord)
            Button {
                Task { await model.markWords() }
            } label: {
                Label(L10n.t("Mark every match"), systemImage: "magnifyingglass")
                    .frame(minHeight: 44)
            }
            .disabled(!model.canFindWords || model.working)
            LabelledField(L10n.t("Kind of data")) {
                Picker(L10n.t("Kind of data"), selection: $model.kindIndex) {
                    ForEach(Array(DataKind.all.enumerated()), id: \.offset) { Text($0.element.name).tag($0.offset) }
                }
                .labelsHidden()
            }
            Button {
                Task { await model.markKind() }
            } label: {
                Label(L10n.t("Mark all of this kind"), systemImage: "magnifyingglass")
                    .frame(minHeight: 44)
            }
            .disabled(model.working)
        }
    }

    private var marksList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.plural(model.marks.count, one: "{0} mark", other: "{0} marks"))
                    .font(.headline)
                    .accessibilityAddTraits([.isHeader, .updatesFrequently])
                Spacer()
                if !model.marks.isEmpty {
                    Button(L10n.t("Remove all")) { model.clearMarks() }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.top, 8)
            if model.marks.isEmpty {
                ReasonText(L10n.t("Nothing is marked yet."))
            }
            ForEach(model.marks) { item in
                HStack(spacing: 4) {
                    Button {
                        model.jump(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).lineLimit(1)
                            Text(item.pageText).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.spoken)
                    Button {
                        model.remove(item)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.t("Remove this mark"))
                    .help(L10n.t("Remove this mark"))
                }
                .padding(.horizontal, 4)
                .background(model.selected == item.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
            #if os(macOS)
            .onDeleteCommand { model.removeSelected() }
            #endif
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(L10n.t("Cover"))
            LabelledField(L10n.t("Colour")) {
                Picker(L10n.t("Colour"), selection: $model.coverIndex) {
                    ForEach(Array(Cover.all.enumerated()), id: \.offset) { Text($0.element.name).tag($0.offset) }
                }
                .labelsHidden()
            }
            LabelledField(L10n.t("Text on the boxes (optional)")) {
                TextField(L10n.t("Text on the boxes (optional)"), text: $model.overlayText)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var optionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeading(L10n.t("Options"))
            Toggle(L10n.t("Flatten every marked page"), isOn: $model.flattenAll)
            ReasonText(L10n.t("Each marked page becomes a picture. Its text can no longer be selected."))
        }
    }
}

private struct ResultCard: View {
    let result: RedactSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(result.title, systemImage: result.clean ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(result.clean ? Color.green : Color.orange)
                .accessibilityAddTraits(.updatesFrequently)
            Text(result.advice).font(.callout)
            if !result.report.isEmpty { Text(result.report).font(.callout) }
            if !result.problems.isEmpty { Text(result.problems).font(.callout).foregroundStyle(.red) }
            ReasonText(result.notChecked)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Result of the redaction"))
    }
}
#endif
