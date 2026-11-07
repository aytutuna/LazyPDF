#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import LazyPDFApp
import LazyPDFKit

// The view of SignaturesModel; follows windows/LazyPDF.App/Panels/Signatures/SignaturesSidePanel.xaml.

public struct SignaturesPanelView: View {
    let model: SignaturesModel
    @State private var saving = false
    @State private var file = BytesDocument()
    @State private var fileName = ""
    @State private var choosing = false

    public init(model: SignaturesModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    SignatureRowView(row: row, isSelected: row.id == model.selected)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.select(row.id)
                            model.go(row)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.summary)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(row.id == model.selected ? .isSelected : [])
                }
                if let note = model.note {
                    PanelNote(note)
                }
                if let row = model.selectedRow {
                    details(row)
                }
                trust
            }
        }
        .accessibilityLabel(L10n.t("Signatures"))
        .fileExporter(isPresented: $saving, document: file, contentType: .pdf, defaultFilename: fileName) { model.signedVersionSaved($0) }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.x509Certificate, .data]) { result in
            if case .success(let url) = result { model.addTrusted(read(url)) }
        }
    }

    private func details(_ row: SignatureRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(row.sections, id: \.heading) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.heading).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                }
            }
            HStack {
                Button { Task { await model.viewSigned() } } label: {
                    Label(L10n.t("View signed version"), systemImage: "doc.text.magnifyingglass")
                }
                .disabled(!model.canViewSigned)
                Button { saveSigned() } label: {
                    Label(L10n.t("Save it"), systemImage: "square.and.arrow.down")
                }
                .help(L10n.t("Save the signed version as a file"))
                .accessibilityLabel(L10n.t("Save the signed version as a file"))
                .disabled(!model.canSaveSigned)
            }
            if let text = model.versionText {
                Text(text).font(.callout).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(12)
    }

    private var trust: some View {
        DisclosureGroup(L10n.t("Trust settings")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.t("Trust what the system trusts"), isOn: Binding(get: { model.trustsSystem }, set: { model.setTrustsSystem($0) }))
                Text(L10n.t("Certificates you trust")).font(.subheadline.weight(.semibold))
                if model.trusted.isEmpty {
                    Text(L10n.t("None added.")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.trusted) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.name).lineLimit(1)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { model.removeTrusted(row) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.t("Remove"))
                        .accessibilityLabel(L10n.t("Remove"))
                    }
                }
                Button { choosing = true } label: {
                    Label(L10n.t("Add a certificate"), systemImage: "plus")
                }
                if let note = model.trustNote {
                    Text(note).font(.callout).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .accessibilityLabel(L10n.t("Trust settings"))
    }

    private func saveSigned() {
        guard let signed = model.signedVersionFile() else { return }
        file = BytesDocument(bytes: signed.bytes)
        fileName = signed.name
        saving = true
    }

    private func read(_ url: URL) -> [UInt8] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? Data(contentsOf: url)).map { [UInt8]($0) } ?? []
    }
}

private struct SignatureRowView: View {
    let row: SignatureRow
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.symbol)
                .foregroundStyle(color)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).fontWeight(.semibold)
                Text(row.status).font(.callout)
                Text(row.sentence).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private var color: Color {
        switch row.level {
        case .good: return .green
        case .caution: return .orange
        case .bad: return .red
        case .unknown: return .secondary
        }
    }
}
#endif
