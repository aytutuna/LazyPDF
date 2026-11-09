#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of CombineModel; follows windows/LazyPDF.App/Tools/Combine/CombinePanel.xaml.

struct CombinePanelView: View {
    @Bindable var model: CombineModel

    var body: some View {
        ToolForm {
            Picker(L10n.t("Combine"), selection: Binding(get: { model.splitting }, set: { model.setSplitting($0) })) {
                Text(L10n.t("Combine")).tag(false).accessibilityLabel(L10n.t("Combine files"))
                Text(L10n.t("Split")).tag(true).accessibilityLabel(L10n.t("Split this file"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.isSigned { SignedNote(L10n.t("This file is signed. The new files do not keep its signatures.")) }
            if model.splitting { splitView } else { combineView }
            LabelledField(L10n.t("Result")) {
                Picker(L10n.t("Result"), selection: $model.toFolder) {
                    Text(L10n.t("Open in new tabs")).tag(false)
                    Text(L10n.t("Save to a folder")).tag(true)
                }
                .labelsHidden()
            }
        }
        .sourceQuestion(model.asker)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.pathExtension.lowercased() == "pdf" }.map { ToolFile(url: $0, access: SecurityScopedAccess.start($0)) }
            if files.isEmpty { return false }
            Task { await model.add(files) }
            return true
        }
    }

    private var combineView: some View {
        LabelledField(L10n.t("Files in order")) {
            VStack(spacing: 6) {
                ForEach(model.entries) { entry in
                    EntryRow(model: model, entry: entry)
                }
            }
            .accessibilityLabel(L10n.t("Files to combine"))
            Button { Task { await model.addFiles() } } label: {
                Label(L10n.t("Add files"), systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
    }

    private var splitView: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabelledField(L10n.t("Split by")) {
                Picker(L10n.t("Split by"), selection: Binding(get: { model.splitKind }, set: { model.setKind($0) })) {
                    Text(L10n.t("Number of pages")).tag(SplitBy.count)
                    Text(L10n.t("File size")).tag(SplitBy.size)
                    Text(L10n.t("Bookmarks")).tag(SplitBy.bookmarks)
                }
                .labelsHidden()
            }
            if model.showsAmount {
                LabelledField(model.amountLabel) {
                    TextField(L10n.t("Amount per part"), text: $model.amount)
                        .textFieldStyle(.roundedBorder)
                        .numberField()
                }
            }
            if !model.splitHint.isEmpty { ReasonText(model.splitHint) }
        }
    }
}

// One file of the list: its name and pages, the buttons that move it, and the pages to take. A row also moves by dragging it onto
// another.
private struct EntryRow: View {
    let model: CombineModel
    @Bindable var entry: CombineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                BarButton("chevron.up", L10n.t("Move up")) { model.moveUp(entry) }
                BarButton("chevron.down", L10n.t("Move down")) { model.moveDown(entry) }
                BarButton("xmark", L10n.t("Remove from the list")) { model.remove(entry) }
            }
            TextField(L10n.t("All pages"), text: $entry.range)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityLabel(entry.rangeName)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .draggable(entry.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = model.entries.first(where: { items.contains($0.id.uuidString) }) else { return false }
            model.move(dragged, onto: entry)
            return true
        }
    }
}
#endif
