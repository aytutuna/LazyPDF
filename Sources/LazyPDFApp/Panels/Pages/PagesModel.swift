import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Pages/PagesSidePanel.xaml.cs.

/// Every page as a small picture, the page in view marked; choosing one goes to the page.
@MainActor
@Observable
public final class PagesModel: ToolPanelModel {
    static let boxWidth = 132.0
    static let boxHeight = 190.0

    public private(set) var thumbs: [PageThumb] = []

    @ObservationIgnored private var tab: DocumentTab?
    @ObservationIgnored private var viewer: DocumentViewer?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var scale = 2.0

    public init() {}

    public var action: ToolAction? { nil }

    /// The page in view, which the list marks; -1 while there are no pages.
    public var current: Int {
        guard let viewer, !thumbs.isEmpty else { return -1 }
        return min(max(viewer.pageIndex, 0), thumbs.count - 1)
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.build() })
        build()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        thumbs = []
        tab = nil
        viewer = nil
    }

    /// Pixels per point of the screen the list is on; the thumbnails are drawn at that density.
    public func setScale(_ value: Double) {
        guard value != scale else { return }
        scale = value
        if tab != nil { build() }
    }

    public func select(_ page: Int) {
        guard let viewer, page >= 0, page < thumbs.count, viewer.pageIndex != page else { return }
        viewer.goToPage(page)
    }

    private func build() {
        guard let tab, let viewer else { return }
        thumbs = (0..<viewer.pageCount).map { page in
            let size = viewer.pageSize(page)
            let fit = min(Self.boxWidth / max(size.width, 1), Self.boxHeight / max(size.height, 1))
            return PageThumb(index: page, label: viewer.pageLabel(page), width: (size.width * fit).rounded(),
                             height: (size.height * fit).rounded(), dpi: fit * 72 * scale, renderer: tab.renderer)
        }
    }
}
