#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import LazyPDFApp

// Follows windows/LazyPDF.App/TabPageDrop.cs: pages dragged from a grid and let go on the strip. A tab of another file takes
// a copy at its end, the empty part of the strip makes a new tab, and Home and the tab the pages are in refuse. The tab id drags
// of TabStrip are another type and pass these by.

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
    /// A tab id dragged on the iPhone and iPad, which let go on this tab reorders the strip; nil where the drop is the page copy only.
    let moveTab: ((String) -> Bool)?

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
        isPage(info) || (moveTab != nil && info.hasItemsConforming(to: [.plainText]))
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
        if !isPage(info) { return dropTab(info) }
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

    private func dropTab(_ info: DropInfo) -> Bool {
        guard let moveTab, let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { id, _ in
            guard let id = id as? String else { return }
            Task { @MainActor in _ = moveTab(id) }
        }
        return true
    }
}

private struct PageDropTarget: ViewModifier {
    let vm: AppViewModel
    let moveTab: ((String) -> Bool)?
    let place: PageDropPlace
    @State private var hot = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [PageDrag.type, .plainText], delegate: TabPageDrop(vm: vm, place: place, hot: $hot, moveTab: moveTab))
            .overlay {
                // The status line says what happened, so the outline is only a hint.
                if hot { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).accessibilityHidden(true) }
            }
    }
}

extension View {
    func pageDropTarget(_ vm: AppViewModel, _ place: PageDropPlace, moveTab: ((String) -> Bool)? = nil) -> some View {
        modifier(PageDropTarget(vm: vm, moveTab: moveTab, place: place))
    }
}
#endif
