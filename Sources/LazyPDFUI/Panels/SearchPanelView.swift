#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of SearchModel; follows windows/LazyPDF.App/Panels/Search/SearchSidePanel.xaml.

public struct SearchPanelView: View {
    let model: SearchModel

    public init(model: SearchModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button { model.showFind() } label: {
                    Label(L10n.t("Search"), systemImage: "magnifyingglass")
                }
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .padding(12)
            List(selection: Binding(get: { model.current >= 0 ? model.current : nil }, set: { model.select($0 ?? -1) })) {
                ForEach(Array(model.hits.enumerated()), id: \.offset) { index, hit in
                    HitRow(hit: hit)
                        .tag(index)
                        .accessibilityLabel(hit.spoken)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel(L10n.t("Search results"))
        }
    }
}

private struct HitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(words).lineLimit(2)
            Text(hit.pageText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var words: AttributedString {
        var match = AttributedString(hit.text)
        match.font = .body.bold()
        return AttributedString(hit.before) + match + AttributedString(hit.after)
    }
}
#endif
