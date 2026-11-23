#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import LazyPDFApp

// Follows windows/LazyPDF.App/TabPageDrop.cs: pages dragged from a grid and let go on the strip. A tab of another file takes
// a copy at its end, the empty part of the strip makes a new tab, and Home and the tab the pages are in refuse. A tab's own
// drag is taken by the same onDrop (TabIdDrop), since a dropDestination beside it keeps the page drag from reaching this delegate.

/// Where on the strip a page drag is let go.
enum PageDropPlace {
    case tab(DocumentTab)
    case home
    case emptyStrip
}

private struct TabPageDrop: DropDelegate {
    let vm: AppViewModel
    let place: PageDropPlace
    @Binding var hot: Bool
    /// What a drag of a tab let go here does; nil where only pages are taken.
    let tabs: TabIdDrop?

    private var accepts: Bool {
        switch place {
        case .tab(let tab): PageTransfer.canDrop(onto: tab, host: vm)
        case .home: false
        case .emptyStrip: PageTransfer.canDropOnStrip(host: vm)
        }
    }

    private func isPage(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [PageDrag.type])
    }

    func validateDrop(info: DropInfo) -> Bool {
        isPage(info) || (tabs.map { info.hasItemsConforming(to: $0.types) } ?? false)
    }

    func dropEntered(info: DropInfo) {
        if case .tab = place, isPage(info) { hot = accepts }
    }

    // A tab that refuses still says so, so that a drop on it is not handed to the strip behind it, which would open a new tab.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isPage(info) else { return DropProposal(operation: .move) }
        return DropProposal(operation: accepts ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        hot = false
    }

    func performDrop(info: DropInfo) -> Bool {
        hot = false
        if !isPage(info) { return tabs?.take(info) ?? false }
        guard accepts else {
            PageDragSession.end()
            return false
        }
        let host = vm
        let place = place
        Task { @MainActor in
            switch place {
            case .tab(let tab): await PageTransfer.drop(onto: tab, host: host)
            case .emptyStrip: await PageTransfer.dropOnStrip(host: host)
            case .home: break
            }
        }
        return true
    }

}

private struct PageDropTarget: ViewModifier {
    let vm: AppViewModel
    let place: PageDropPlace
    let tabs: TabIdDrop?
    @State private var hot = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [PageDrag.type] + (tabs?.types ?? []), delegate: TabPageDrop(vm: vm, place: place, hot: $hot, tabs: tabs))
            .overlay {
                // The status line says what happened, so the outline is only a hint.
                if hot { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).accessibilityHidden(true) }
            }
    }
}

extension View {
    func pageDropTarget(_ vm: AppViewModel, _ place: PageDropPlace, tabs: TabIdDrop? = nil) -> some View {
        modifier(PageDropTarget(vm: vm, place: place, tabs: tabs))
    }
}
#endif
