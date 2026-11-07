import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/PageViewer.Navigation.cs: pages, destinations, the history, the find bar and the question
// before an address opens.

extension ViewerModel {
    private static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    public var canGoBack: Bool {
        _ = shownRevision
        return history.canGoBack
    }

    public var canGoForward: Bool {
        _ = shownRevision
        return history.canGoForward
    }

    public func goToPage(_ page: Int) {
        guard tab != nil, state.pageCount > 0 else { return }
        let target = Swift.min(Swift.max(page, 0), state.pageCount - 1)
        history.jump(state.currentPage, target)
        apply(state.goToPage(target))
        shownRevision += 1
    }

    /// The next or previous page, or spread when facing pages show.
    public func stepPage(_ direction: Int) {
        guard state.pageCount > 0 else { return }
        let spread = ViewLayout.spreadOf(state.columns, state.cover, state.currentPage) + direction
        if spread < 0 || spread >= ViewLayout.spreadsOf(state.columns, state.cover, state.pageCount) { return }
        goToPage(ViewLayout.pagesOf(state.columns, state.cover, spread, state.pageCount).first)
    }

    public func goTo(_ destination: PdfDestination) {
        guard let tab, let place = PdfDestinations.locate(tab.document, destination) else { return }
        history.jump(state.currentPage, place.pageIndex)
        apply(state.goToPage(place.pageIndex, at: ViewPoint(place.x, Swift.max(0, place.y - 12))))
        shownRevision += 1
    }

    public func follow(_ action: PdfAction?) {
        switch action {
        case let go as GoToAction:
            goTo(go.destination)
        case let uri as UriAction:
            askToOpen(uri.uri)
        case let named as NamedAction:
            perform(named.name)
        default:
            break
        }
    }

    private func perform(_ name: String) {
        switch name {
        case "NextPage": stepPage(1)
        case "PrevPage": stepPage(-1)
        case "FirstPage": goToPage(0)
        case "LastPage": goToPage(state.pageCount - 1)
        case "GoBack": goBack()
        case "GoForward": goForward()
        case "Find": showFind()
        default: break
        }
    }

    public func goBack() {
        guard let page = history.goBack(state.currentPage) else { return }
        apply(state.goToPage(page))
        shownRevision += 1
    }

    public func goForward() {
        guard let page = history.goForward(state.currentPage) else { return }
        apply(state.goToPage(page))
        shownRevision += 1
    }

    public func reveal(_ page: Int, _ area: ViewRect) {
        apply(state.reveal(page, area))
    }

    // MARK: The page box

    public func showGoToPage() {
        guard tab != nil else { return }
        if readingMode { readingMode = false }
        goToPageVisible = true
    }

    /// Goes to the page the person typed: a label of the file, else a number from 1. False when there is no such page.
    @discardableResult
    public func goToPage(typed text: String) -> Bool {
        guard let tab else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let page = PdfPageLabels.find(tab.document, trimmed) ?? Int(trimmed).map { $0 - 1 }
        guard let page, page >= 0, page < state.pageCount else { return false }
        goToPage(page)
        return true
    }

    // MARK: Find

    public func showFind() {
        guard tab != nil else { return }
        if readingMode { readingMode = false }
        findSeed = selected.isEmpty || selected.start.page != selected.end.page ? nil : selectedOnOnePage()
        findVisible = true
        findRequest += 1
    }

    public func hideFind() {
        guard findVisible else { return }
        findVisible = false
        search.clear()
    }

    func watchSearch() {
        search.onCurrentChanged = { [weak self] in self?.searchMoved() }
        trackSearch()
    }

    private func trackSearch() {
        withObservationTracking {
            _ = search.hits.count
            _ = search.current
            _ = search.query
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hitShapes.removeAll()
                self.onRedraw?()
                self.trackSearch()
            }
        }
    }

    private func searchMoved() {
        guard search.current >= 0, search.current < search.hits.count else { return }
        let hit = search.hits[search.current].match
        guard tab != nil, !hit.quads.isEmpty else { return }
        history.jump(state.currentPage, hit.page)
        apply(state.reveal(hit.page, pageBounds(hit.page, hit.quads)))
        shownRevision += 1
        hitShapes.removeAll()
        onRedraw?()
    }

    // MARK: Addresses

    // An address in a file is the file's, not the reader's: it is shown and asked about, and only the usual schemes are opened.
    func askToOpen(_ address: String) {
        let scheme = URL(string: address)?.scheme?.lowercased()
        pendingAddress = PendingAddress(address: address, openable: scheme.map(Self.openableSchemes.contains) ?? false)
    }

    public func openPendingAddress() {
        guard let pending = pendingAddress else { return }
        pendingAddress = nil
        if pending.openable, let url = URL(string: pending.address) { openAddress(url) }
    }

    public func dismissPendingAddress() {
        pendingAddress = nil
    }

    func followLink(_ link: PdfLink) {
        if let action = link.action {
            follow(action)
        } else if let destination = link.destination {
            goTo(destination)
        }
    }
}
