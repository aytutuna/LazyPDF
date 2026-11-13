import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Search/SearchSidePanel.xaml.cs. The search is the viewer's, which the find bar shares,
// so the model only reads it: a view that reads `summary` or `hits` follows the search.

/// The hits of the find bar's search, with the words around each; choosing one goes to the hit.
@MainActor
@Observable
public final class SearchModel: ToolPanelModel {
    private var viewer: DocumentViewer?

    public init() {}

    public var action: ToolAction? { nil }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.viewer = viewer
    }

    public func detach() {
        viewer = nil
    }

    public var hits: [SearchHit] { viewer?.search.hits ?? [] }

    /// The hit the viewer is at, or -1.
    public var current: Int { viewer?.search.current ?? -1 }

    public var summary: String {
        guard let search = viewer?.search else { return "" }
        if search.query.isEmpty { return L10n.t("Search the file to list every match here.") }
        if search.badPattern { return L10n.t("Not a valid pattern") }
        if search.isRunning { return search.hits.isEmpty ? L10n.t("Searching for {0}", search.query) : L10n.t("{0} found", search.hits.count) }
        if search.stopped { return search.hits.isEmpty ? L10n.t("Stopped") : L10n.t("{0} found, stopped", search.hits.count) }
        let slow = TimedOutText.forPages(search.timedOut)
        if search.hits.isEmpty { return slow ?? L10n.t("No results for {0}", search.query) }
        var found = L10n.plural(search.hits.count, one: "{0} result for {1}", other: "{0} results for {1}", search.query)
        if search.capped { found += " " + L10n.t("First {0} shown. Narrow the search to see the rest.", ViewerSearch.maxHits) }
        return slow.map { "\(found) \($0)" } ?? found
    }

    public var isSearching: Bool { viewer?.search.isRunning ?? false }

    public func stop() {
        viewer?.search.stop()
    }

    public func select(_ index: Int) {
        guard index >= 0 else { return }
        viewer?.search.select(index)
    }

    public func showFind() {
        viewer?.showFind()
    }
}
