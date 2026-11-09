#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import LazyPDFApp
import LazyPDFKit

// The grid of pages of the Pages panel and the organize view; follows the ListBox `Thumbs` of PagesPanel.xaml and OrganizeView.xaml
// with the drag of PageDrag.cs. A tap chooses or unchooses a page, which needs no modifier key and so works with a finger. A page
// moves by dragging, and always by the menu of the page and the buttons over the grid too.

struct PageGridView: View {
    let grid: PageGrid
    let cellWidth: Double
    let cellHeight: Double

    /// Set where files may be dropped between the pages: gets the files and the index they go before.
    var onFiles: (([ToolFile], Int) -> Void)?

    /// Set where a double tap on a page does something.
    var open: ((Int) -> Void)?

    /// Set where the Delete key removes the chosen pages.
    var onDelete: (() -> Void)?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth), spacing: 8)], spacing: 6) {
                ForEach(grid.cells) { cell in
                    PageTile(cell: cell, grid: grid, onFiles: onFiles, open: open)
                        .frame(height: cellHeight)
                }
            }
            .padding(8)
        }
        .onDrop(of: [.fileURL], delegate: PageDropDelegate(grid: grid, page: nil, width: 0, onFiles: onFiles))
        .focusable(onDelete != nil)
        .onKeyPress(.delete) { removeChosen() }
        .onKeyPress(.deleteForward) { removeChosen() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Pages"))
    }

    private func removeChosen() -> KeyPress.Result {
        guard let onDelete, !grid.selected.isEmpty else { return .ignored }
        onDelete()
        return .handled
    }
}

struct PageTile: View {
    let cell: PageCell
    let grid: PageGrid
    var onFiles: (([ToolFile], Int) -> Void)?
    var open: ((Int) -> Void)?
    @Environment(\.displayScale) private var displayScale
    @State private var tileWidth = 0.0

    var body: some View {
        let chosen = grid.selected.contains(cell.index)
        VStack(spacing: 4) {
            picture
                .frame(width: cell.width, height: cell.height)
                .background(Color.white)
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            Text(cell.label)
                .font(.caption)
                .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.2) : Color.clear))
        .overlay(alignment: .leading) { if cell.dropBefore { DropMark() } }
        .overlay(alignment: .trailing) { if cell.dropAfter { DropMark() } }
        .background(GeometryReader { proxy in Color.clear.preference(key: TileWidthKey.self, value: proxy.size.width) })
        .onPreferenceChange(TileWidthKey.self) { tileWidth = $0 }
        .contentShape(Rectangle())
        .modifier(DoubleTap(action: open.map { open in { open(cell.index) } }))
        .onTapGesture { grid.toggle(cell.index) }
        .onDrag {
            grid.dragging = grid.target(cell.index)
            return NSItemProvider(object: L10n.t("Pages") as NSString)
        }
        .onDrop(of: [.plainText, .fileURL], delegate: PageDropDelegate(grid: grid, page: cell.index, width: tileWidth, onFiles: onFiles))
        .contextMenu { menu }
        .onAppear { cell.appear(displayScale: displayScale) }
        .onDisappear { cell.disappear() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cell.name)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text(L10n.t("Rotate left"))) { grid.turn([cell.index], -90) }
        .accessibilityAction(named: Text(L10n.t("Rotate right"))) { grid.turn([cell.index], 90) }
        .accessibilityAction(named: Text(L10n.t("Move earlier"))) { grid.earlier(grid.target(cell.index)) }
        .accessibilityAction(named: Text(L10n.t("Move later"))) { grid.later(grid.target(cell.index)) }
    }

    @ViewBuilder
    private var picture: some View {
        if let image = cell.image.flatMap(PanelImage.make) {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }

    // The menu is about the page alone for a turn, and about the chosen pages when the page is one of them.
    @ViewBuilder
    private var menu: some View {
        let pages = grid.target(cell.index)
        Button(L10n.t("Rotate left"), systemImage: "rotate.left") { grid.turn([cell.index], -90) }
        Button(L10n.t("Rotate right"), systemImage: "rotate.right") { grid.turn([cell.index], 90) }
        Button(L10n.t("Move earlier"), systemImage: "arrow.left") { grid.earlier(pages) }
        Button(L10n.t("Move later"), systemImage: "arrow.right") { grid.later(pages) }
        Button(L10n.t("Duplicate"), systemImage: "plus.square.on.square") { Task { await grid.duplicate(pages) } }
        Button(L10n.t("Extract to a new file"), systemImage: "arrow.up.doc") { Task { await grid.extract(pages) } }
        Button(L10n.t("Delete"), systemImage: "trash", role: .destructive) { grid.remove(pages) }
    }
}

private struct TileWidthKey: PreferenceKey {
    static let defaultValue = 0.0

    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = nextValue()
    }
}

// Only a grid that does something with a double tap waits to tell it from a single one.
private struct DoubleTap: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onTapGesture(count: 2, perform: action)
        } else {
            content
        }
    }
}

private struct DropMark: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}

// Pages dragged over a tile mark the gap on its near side; files dragged over it go to the same gap. The grid itself takes the
// files that fall between the tiles, to the end.
private struct PageDropDelegate: DropDelegate {
    let grid: PageGrid
    let page: Int?
    let width: Double
    let onFiles: (([ToolFile], Int) -> Void)?

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.fileURL]) { return onFiles != nil }
        return page != nil && !grid.dragging.isEmpty
    }

    func dropEntered(info: DropInfo) {
        mark(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        mark(info)
        return DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        grid.unmark()
    }

    func performDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.fileURL]) {
            guard let onFiles else { return false }
            let before = page == nil ? grid.cells.count : grid.dropIndex
            grid.unmark()
            grid.dragging = []
            let providers = info.itemProviders(for: [.fileURL])
            Task { @MainActor in
                var files: [ToolFile] = []
                for provider in providers {
                    if let url = await Self.fileURL(provider) { files.append(ToolFile(url: url, access: SecurityScopedAccess.start(url))) }
                }
                if !files.isEmpty { onFiles(files, before) }
            }
            return true
        }
        guard !grid.dragging.isEmpty else { return false }
        grid.dropPages()
        return true
    }

    private func mark(_ info: DropInfo) {
        guard let page else { return }
        grid.mark(page, after: info.location.x > width / 2)
    }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
#endif
