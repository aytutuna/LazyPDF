#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// Follows windows/LazyPDF.App/HomeView.xaml(.cs): the jobs people come for as tiles, then the files opened last. A tile that
// cannot be started stays a button, so a screen reader reads why; it starts nothing.

struct HomeScreen: View {
    let vm: AppViewModel
    let chooseTile: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("What would you like to do?"))
                    .font(.title.bold())
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(vm.tiles, id: \.id) { tile in
                        TileButton(tile: tile) { chooseTile(tile.id) }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.t("Jobs"))
                recent
            }
            .padding(16)
        }
        .accessibilityLabel(L10n.t("What would you like to do?"))
    }

    @ViewBuilder private var recent: some View {
        if vm.recent.isEmpty {
            Text(L10n.t("Files you open show up here."))
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        } else {
            HStack {
                Text(L10n.t("Recent files"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(L10n.t("Clear list")) { vm.clearRecent() }
                    .accessibilityLabel(L10n.t("Clear the recent files"))
            }
            .padding(.top, 24)
            .padding(.bottom, 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(vm.recent, id: \.url) { item in
                    RecentCard(item: item) { Task { await vm.openRecent(item) } }
                        .contextMenu {
                            Button(L10n.t("Remove from list")) { vm.forgetRecent(item.url) }
                        }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("Recent files"))
        }
    }
}

private struct TileButton: View {
    let tile: HomeTile
    let start: () -> Void

    var body: some View {
        Button(action: start) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: tile.symbol)
                    .font(.title)
                    .opacity(tile.available ? 1 : 0.4)
                Text(tile.title)
                    .font(.headline)
                    .opacity(tile.available ? 1 : 0.7)
                if let reason = tile.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(tile.helpText)
        .accessibilityLabel(tile.title)
        .accessibilityHint(tile.helpText)
    }
}

private struct RecentCard: View {
    let item: RecentItem
    let open: () -> Void

    var body: some View {
        let caption = item.exists ? "\(item.opened) \u{00B7} \(item.folder)" : L10n.t("Not found")
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    Image(systemName: "doc.richtext")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .opacity(0.6)
                }
                .frame(height: 110)
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 4)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(item.url.path)
        .accessibilityLabel(item.name)
        .accessibilityHint(caption)
    }
}
#endif
