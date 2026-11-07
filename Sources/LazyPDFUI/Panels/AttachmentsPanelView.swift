#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import LazyPDFApp
import LazyPDFKit
#if os(macOS)
import AppKit
#else
import QuickLook
#endif

// The view of AttachmentsModel; follows windows/LazyPDF.App/Panels/Attachments/AttachmentsSidePanel.xaml. The Mac opens the
// copy in the program that handles its type; the iPhone and iPad show it in Quick Look.

public struct AttachmentsPanelView: View {
    let model: AttachmentsModel
    @State private var saving = false
    @State private var file = BytesDocument()
    @State private var fileName = ""
    #if os(iOS)
    @State private var preview: URL?
    #endif

    public init(model: AttachmentsModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.rows.isEmpty {
                PanelNote(L10n.t("This file has no attachments.")).frame(maxHeight: .infinity, alignment: .top)
            } else {
                List(selection: Binding(get: { model.selected }, set: { model.selected = $0 })) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            if !row.details.isEmpty {
                                Text(row.details).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(row.id)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.summary)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel(L10n.t("Attachments"))
                .contextMenu(forSelectionType: Int.self) { _ in
                } primaryAction: { _ in
                    model.open()
                }
            }
            if let note = model.note {
                PanelNote(note)
            }
            HStack {
                Button(L10n.t("Open")) { model.open() }
                Button(L10n.t("Save as")) { save() }
                Spacer()
            }
            .disabled(model.selected == nil)
            .padding(12)
        }
        .onAppear { model.launch = launch }
        .fileExporter(isPresented: $saving, document: file, contentType: .data, defaultFilename: fileName) { model.saved($0) }
        #if os(iOS)
        .quickLookPreview($preview)
        #endif
    }

    private func save() {
        guard let saved = model.fileToSave() else { return }
        file = BytesDocument(bytes: saved.bytes)
        fileName = saved.name
        saving = true
    }

    private func launch(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        preview = url
        return true
        #endif
    }
}
#endif
