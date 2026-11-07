#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of LayersModel; follows windows/LazyPDF.App/Panels/Layers/LayersSidePanel.xaml.

public struct LayersPanelView: View {
    let model: LayersModel

    public init(model: LayersModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isEmpty {
                PanelNote(L10n.t("This file has no layers.")).frame(maxHeight: .infinity, alignment: .top)
            } else {
                List {
                    ForEach(model.roots) { LayerRowView(row: $0, model: model) }
                }
                .listStyle(.sidebar)
                .accessibilityLabel(L10n.t("Layers"))
            }
            Text(L10n.t("Showing or hiding a layer changes the view only. The file stays as it is."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

private struct LayerRowView: View {
    let row: LayerRow
    let model: LayersModel
    @State private var open = true

    var body: some View {
        if let children = row.children {
            DisclosureGroup(isExpanded: $open) {
                ForEach(children) { LayerRowView(row: $0, model: model) }
            } label: {
                header
            }
        } else {
            header
        }
    }

    @ViewBuilder
    private var header: some View {
        if row.layer == nil {
            Text(row.name).fontWeight(.semibold)
        } else {
            Toggle(row.name, isOn: Binding(get: { row.isOn }, set: { model.toggle(row, $0) }))
                .disabled(!row.canToggle)
        }
    }
}
#endif
