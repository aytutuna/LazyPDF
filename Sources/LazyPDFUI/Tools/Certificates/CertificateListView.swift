#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The imported identities of the phone: swipe a row or use Edit to delete one, and import another from a .p12 file.

struct CertificateListView: View {
    let model: CertificateListModel
    let done: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.items) { choice in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.name)
                        if !choice.issuer.isEmpty { Text(choice.issuer).font(.caption).foregroundStyle(.secondary) }
                        Text(L10n.t("Expires {0}", choice.expires.formatted(date: .abbreviated, time: .omitted)))
                            .font(.caption)
                            .foregroundStyle(choice.isValidNow ? Color.secondary : Color.red)
                    }
                    .accessibilityElement(children: .combine)
                }
                .onDelete { model.remove(at: $0) }
                if model.items.isEmpty { Text(L10n.t("No imported certificates.")).foregroundStyle(.secondary) }
                if !model.note.isEmpty {
                    Text(model.note).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                }
                Button {
                    Task { await model.importOne() }
                } label: {
                    Label(L10n.t("Import a .p12 file"), systemImage: "square.and.arrow.down")
                        .frame(minHeight: 44)
                }
            }
            .navigationTitle(L10n.t("Certificates"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("Done"), action: done) }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) { EditButton() }
                #endif
            }
        }
        .onAppear { model.reload() }
    }
}
#endif
