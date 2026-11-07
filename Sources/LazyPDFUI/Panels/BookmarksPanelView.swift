#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of BookmarksModel; follows windows/LazyPDF.App/Panels/Bookmarks/BookmarksSidePanel.xaml.

public struct BookmarksPanelView: View {
    let model: BookmarksModel

    public init(model: BookmarksModel) {
        self.model = model
    }

    public var body: some View {
        if model.nodes.isEmpty {
            PanelNote(L10n.t("This file has no bookmarks.")).frame(maxHeight: .infinity, alignment: .top)
        } else {
            List {
                ForEach(model.nodes) { BookmarkRow(node: $0, model: model) }
            }
            .listStyle(.sidebar)
            .accessibilityLabel(L10n.t("Bookmarks"))
        }
    }
}

private struct BookmarkRow: View {
    let node: BookmarkNode
    let model: BookmarksModel

    var body: some View {
        if node.children.isEmpty {
            entry
        } else {
            DisclosureGroup(isExpanded: Binding(get: { model.isExpanded(node) }, set: { model.setExpanded(node, $0) })) {
                ForEach(node.children) { BookmarkRow(node: $0, model: model) }
            } label: {
                entry
            }
        }
    }

    private var entry: some View {
        Button { model.go(node) } label: {
            Text(node.title)
                .fontWeight(node.bold ? .semibold : .regular)
                .italic(node.italic)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(node.title)
    }
}
#endif
