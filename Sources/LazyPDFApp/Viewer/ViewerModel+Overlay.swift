import Foundation

// The overlays of windows/LazyPDF.App/Viewer/PageSurface.Overlays.cs: one layer of marks for each page a tool has asked for.

extension ViewerModel {
    public func overlay(_ page: Int) -> PageOverlay {
        if let known = overlays[page] { return known }
        let made = PageOverlay(page: page, size: state.pageSize(page))
        made.onChange = { [weak self] in self?.onRedraw?() }
        overlays[page] = made
        return made
    }

    func clearOverlays() {
        let old = overlays.values
        overlays.removeAll()
        for overlay in old { overlay.discard() }
    }

    // The pages may have changed size, and a layer of a page that is gone has nothing to sit on.
    func refreshOverlays() {
        for (page, overlay) in overlays {
            if page >= state.pageCount {
                overlays[page] = nil
                overlay.discard()
            } else {
                overlay.size = state.pageSize(page)
            }
        }
    }
}

extension ViewerModel {
    /// The fields tools have open, with their pages, for the page view that puts a control over each.
    public var openFields: [(page: Int, field: OverlayField)] {
        overlays.sorted { $0.key < $1.key }.flatMap { page, overlay in overlay.fields.map { (page, $0) } }
    }
}
