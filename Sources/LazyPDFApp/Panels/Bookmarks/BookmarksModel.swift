import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Bookmarks/BookmarksSidePanel.xaml.cs.

/// An outline entry in the tree. `id` is its place in the outline, which is how the panel remembers whether it is open.
public struct BookmarkNode: Identifiable {
    public let id: String
    public let item: OutlineItem
    public let children: [BookmarkNode]

    public var title: String { item.title }
    public var bold: Bool { item.bold }
    public var italic: Bool { item.italic }

    init(_ item: OutlineItem, _ path: String) {
        id = path
        self.item = item
        children = item.children.enumerated().map { BookmarkNode($1, path + "." + String($0)) }
    }
}

/// The file's outline as a tree; choosing an entry goes to what it points at.
@MainActor
@Observable
public final class BookmarksModel: ToolPanelModel {
    public private(set) var nodes: [BookmarkNode] = []

    // Which entries the person opened or closed, kept while the file is edited and the tree is read again.
    private var opened: [String: Bool] = [:]
    @ObservationIgnored private weak var openedFor: DocumentTab?
    @ObservationIgnored private var tab: DocumentTab?
    @ObservationIgnored private var viewer: DocumentViewer?
    @ObservationIgnored private var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?

    public init() {}

    public var action: ToolAction? { nil }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        if openedFor !== tab {
            opened = [:]
            openedFor = tab
        }
        self.tab = tab
        self.viewer = viewer
        self.host = host
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.build() })
        build()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        nodes = []
        tab = nil
        viewer = nil
        host = nil
    }

    public func isExpanded(_ node: BookmarkNode) -> Bool {
        opened[node.id] ?? node.item.isOpen
    }

    public func setExpanded(_ node: BookmarkNode, _ value: Bool) {
        opened[node.id] = value
    }

    public func go(_ node: BookmarkNode) {
        guard let tab, let viewer else { return }
        let item = node.item
        if let destination = item.destination ?? (item.action as? GoToAction)?.destination {
            if PdfDestinations.locate(tab.document, destination) == nil {
                host?.setStatus(L10n.t("This bookmark points to a page that is not in the file."))
                return
            }
        } else if let action = item.action {
            if !(action is UriAction || action is NamedAction) {
                host?.setStatus(L10n.t("This bookmark does something Lazy PDF cannot do."))
                return
            }
        } else {
            return
        }
        if let destination = item.destination {
            viewer.goTo(destination)
        } else {
            viewer.follow(item.action)
        }
    }

    private func build() {
        guard let tab else { return }
        nodes = Outline.read(tab.document).items.enumerated().map { BookmarkNode($1, String($0)) }
    }
}
