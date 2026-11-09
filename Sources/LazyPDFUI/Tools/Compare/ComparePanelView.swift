#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of CompareModel; follows windows/LazyPDF.App/Tools/Compare/ComparePanel.xaml. The side by side window of Windows is
// a sheet presented from here.

struct ComparePanelView: View {
    @Bindable var model: CompareModel

    var body: some View {
        ToolForm {
            LabelledField(L10n.t("Compare with")) {
                Picker(L10n.t("Compare with"), selection: $model.source) {
                    Text(L10n.t("Another file")).tag(CompareSource.file)
                    Text(L10n.t("Earlier version")).tag(CompareSource.version)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if model.source == .file { fileGroup } else { versionGroup }

            LabelledField(L10n.t("Look at")) {
                Picker(L10n.t("Look at"), selection: $model.byPixels) {
                    Text(L10n.t("Content")).tag(false)
                    Text(L10n.t("Pixels")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ReasonText(model.howText)
            }
            VStack(alignment: .leading) {
                Toggle(L10n.t("Ignore capitals"), isOn: $model.ignoreCase)
                Toggle(L10n.t("Ignore spacing"), isOn: $model.ignoreSpace)
                Toggle(L10n.t("Ignore headers and footers"), isOn: $model.ignoreEdges)
            }
            .disabled(model.byPixels)

            LabelledField(L10n.t("Show")) {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                    part(L10n.t("Text"), .text)
                    part(L10n.t("Pictures"), .pictures)
                    part(L10n.t("Annotations"), .annotations)
                    part(L10n.t("Forms"), .forms)
                    part(L10n.t("Page properties"), .pages)
                    part(L10n.t("File details"), .details)
                }
                .disabled(model.byPixels)
                .opacity(model.byPixels ? 0.5 : 1)
            }

            if model.shown != nil { result }
        }
        #if os(iOS)
        // A plain sheet is a form sheet on an iPad, too narrow for two pages side by side.
        .fullScreenCover(isPresented: sheetShown) { sheetContent }
        #else
        .sheet(isPresented: sheetShown) { sheetContent }
        #endif
    }

    private var sheetShown: Binding<Bool> {
        Binding(get: { model.sheetShown }, set: { if !$0 { model.closeSheet() } })
    }

    @ViewBuilder private var sheetContent: some View {
        if let window = model.shown?.window { CompareSheetView(window: window) { model.closeSheet() } }
    }

    private var fileGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await model.chooseFile() }
            } label: {
                Label(L10n.t("Choose file"), systemImage: "folder").frame(minHeight: 28)
            }
            ReasonText(model.chosenText)
                .lineLimit(1)
                .truncationMode(.middle)
            Toggle(L10n.t("This file is the older one"), isOn: $model.fileIsOlder)
            if let text = model.unlockText {
                ReasonText(text).accessibilityAddTraits(.updatesFrequently)
                if model.unlockNeedsCertificate {
                    Picker(L10n.t("Certificate of the other file"), selection: $model.certificateId) {
                        Text("").tag(String?.none)
                        ForEach(model.certificates) { Text($0.name).tag(Optional($0.id)) }
                    }
                } else {
                    SecureField(L10n.t("Password of the other file"), text: $model.password)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var versionGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.t("Earlier version"), selection: $model.versionIndex) {
                ForEach(Array(model.versionNames.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
            }
            .labelsHidden()
            .disabled(model.versions.isEmpty)
            if model.versions.isEmpty { ReasonText(L10n.t("This file has no earlier versions.")) }
        }
    }

    private func part(_ title: String, _ part: CompareParts) -> some View {
        Toggle(title, isOn: Binding(get: { model.parts.contains(part) }, set: { model.setPart(part, $0) }))
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.summaryText)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            if let note = model.noteText { ReasonText(note) }
            HStack {
                Button {
                    model.openSheet()
                } label: {
                    Label(L10n.t("Side by side"), systemImage: "rectangle.split.2x1").frame(minHeight: 28)
                }
                Button {
                    Task { await model.writeReport() }
                } label: {
                    Label(L10n.t("Write report"), systemImage: "doc.badge.plus").frame(minHeight: 28)
                }
                .disabled(model.isWritingReport)
            }
            ChangeListView(rows: model.rows) { model.go($0) }
                .frame(maxHeight: 300)
        }
        .padding(.top, 8)
    }
}

/// The differences of a comparison, one row each; a tap raises `picked`.
struct ChangeListView: View {
    let rows: [ChangeRow]
    let picked: (ChangeRow) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    Button {
                        picked(row)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(color(row.kind)).frame(width: 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).lineLimit(2)
                                Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.spoken)
                }
            }
        }
        .accessibilityLabel(L10n.t("Differences"))
    }

    private func color(_ kind: ChangeKind?) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case nil: return .accentColor
        default: return .orange
        }
    }
}
#endif
