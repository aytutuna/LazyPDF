#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of BatchModel; follows windows/LazyPDF.App/Tools/Batch/BatchPanel.xaml. The sheet of BatchSheet and the tool of the
// strip both show it.

struct BatchPanelView: View {
    let model: BatchModel

    var body: some View {
        @Bindable var model = model
        ToolForm {
            ReasonText(model.summary)
            savedSets(model)
            SectionHeading(L10n.t("Steps"))
            steps(model)
            if let step = model.step {
                BatchStepEditor(model: model, step: step)
                    .id(model.selected)
            }
            SectionHeading(L10n.t("Results go to"))
            folder(model.outputText, choose: { await model.chooseOutput() }, label: L10n.t("Results folder"))
            LabelledField(L10n.t("File name")) {
                TextField(L10n.t("File name"), text: $model.set.nameTemplate).textFieldStyle(.roundedBorder)
                ReasonText(model.templateHint)
            }
            if let note = model.folderNote { ReasonText(note) }
            SectionHeading(L10n.t("Files"))
            files(model)
            if model.canWatch { watch(model) }
            results(model)
        }
    }

    private func folder(_ path: String, choose: @escaping () async -> Void, label: String) -> some View {
        HStack {
            Text(path)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, 6)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                .accessibilityLabel(label)
                .accessibilityValue(path)
            Button(L10n.t("Browse")) { Task { await choose() } }
        }
    }

    private func savedSets(_ model: BatchModel) -> some View {
        @Bindable var model = model
        return LabelledField(L10n.t("Saved sets")) {
            HStack {
                TextField(L10n.t("Name of the set"), text: $model.setName).textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(model.savedNames, id: \.self) { name in Button(name) { model.loadSet(name) } }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(model.savedNames.isEmpty)
                .accessibilityLabel(L10n.t("Saved sets"))
                Button { model.saveSet() } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel(L10n.t("Save set"))
                Button { model.deleteSet() } label: { Image(systemName: "trash") }
                    .disabled(!model.canDeleteSet)
                    .accessibilityLabel(L10n.t("Delete set"))
            }
        }
    }

    @ViewBuilder
    private func steps(_ model: BatchModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
                Button { model.selected = row.index } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).fontWeight(.semibold)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 6)
                    .background(model.selected == row.index ? Color.accentColor.opacity(0.25) : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.spoken)
                .accessibilityAddTraits(model.selected == row.index ? .isSelected : [])
            }
        }
        if model.set.steps.isEmpty { ReasonText(L10n.t("Add a step to begin.")) }
        HStack {
            Menu {
                ForEach(BatchStepKind.allCases, id: \.self) { kind in Button(BatchText.title(kind)) { model.addStep(kind) } }
            } label: {
                Label(L10n.t("Add step"), systemImage: "plus")
            }
            .fixedSize()
            Button { model.moveSelected(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(model.step == nil || !model.canMoveUp)
                .accessibilityLabel(L10n.t("Move step up"))
            Button { model.moveSelected(1) } label: { Image(systemName: "chevron.down") }
                .disabled(model.step == nil || !model.canMoveDown)
                .accessibilityLabel(L10n.t("Move step down"))
            Button { model.removeSelected() } label: { Image(systemName: "minus") }
                .disabled(model.step == nil)
                .accessibilityLabel(L10n.t("Remove step"))
        }
    }

    @ViewBuilder
    private func files(_ model: BatchModel) -> some View {
        HStack {
            Button { Task { await model.addFiles() } } label: { Label(L10n.t("Add files"), systemImage: "doc.badge.plus") }
            Button { Task { await model.addFolder() } } label: { Label(L10n.t("Add folder"), systemImage: "folder.badge.plus") }
        }
        ForEach(model.files) { file in
            HStack {
                Text(file.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.removeFile(file.id) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(file.removeName)
            }
            .frame(minHeight: 32)
        }
        if model.files.isEmpty { ReasonText(L10n.t("No files yet.")) }
    }

    @ViewBuilder
    private func watch(_ model: BatchModel) -> some View {
        SectionHeading(L10n.t("Watch a folder"))
        Toggle(L10n.t("Run on new files"), isOn: Binding(get: { model.isWatching }, set: { model.setWatching($0) }))
        folder(model.watchText, choose: { await model.chooseWatch() }, label: L10n.t("Folder to watch"))
        ReasonText(model.watchNote).accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func results(_ model: BatchModel) -> some View {
        HStack {
            SectionHeading(L10n.t("Results"))
            Spacer()
            Button(L10n.t("Clear")) { model.clearLog() }.disabled(model.log.isEmpty)
        }
        ForEach(model.log) { row in
            HStack(alignment: .top) {
                Image(systemName: row.result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    Text(row.result.title)
                    Text(row.result.detail).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.spoken)
        }
        if model.log.isEmpty { ReasonText(L10n.t("Nothing has run yet.")) }
    }
}
#endif
