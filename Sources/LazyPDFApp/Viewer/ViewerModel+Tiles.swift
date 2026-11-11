import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/PageSurface.Tiles.cs and PageSurface.Draw.cs (DrawPictures), and PageViewer.Layers.cs: which
// tiles the window needs, who draws them, where they are kept, which of them a page shows, and the layers of the view.

extension ViewerModel {
    func resetTiles() {
        newScheduler()
        cache.clear()
        failed.removeAll()
        settling = false
        settleTask?.cancel()
    }

    // A new document or a tab switch: nothing drawn for the old one may land in the new one.
    private func newScheduler() {
        scheduler?.dispose()
        generation += 1
        let id = generation
        let drawer = self.drawer
        scheduler = TileScheduler(render: { drawer.draw($0) }, done: { [weak self] spec, image in
            let bitmap = image.map { TileBitmap($0, spec.key.tint) }
            Task { @MainActor in self?.deliver(id, spec, bitmap) }
        })
    }

    private func deliver(_ id: Int, _ spec: TileSpec, _ bitmap: TileBitmap?) {
        guard id == generation else { return }
        if let bitmap { cache.add(spec.key, TilePicture(bitmap)) } else { failed.insert(spec.key) }
        onRedraw?()
    }

    /// Tiles waiting or being drawn.
    public var tilesPending: Int { scheduler?.pending ?? 0 }

    func noteZoomChange() {
        if cache.count == 0 { return }
        settling = true
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self else { return }
            self.settling = false
            self.failed = self.failed.filter { $0.isPreview }
            self.planTiles()
        }
    }

    func scheduleTiles() {
        if planQueued { return }
        planQueued = true
        Task { [weak self] in self?.planTiles() }
    }

    // Asks for whatever of the pages near the window is not drawn yet.
    func planTiles() {
        planQueued = false
        guard let scheduler, state.layout.pageCount > 0, displayRenderer != nil || tab?.canDraw == true else { return }
        scheduler.want(state.wantedTiles(settling: settling, isKnown: { [cache, failed] in cache.contains($0) || failed.contains($0) },
                                         reachable: { $0 }))
    }

    /// The pictures of a page to draw over its paper, and whether none could be made. A tile that has not come is stood in for
    /// by a smaller picture; once the sharp ones are all there, the others are let go.
    public func drawing(of page: Int) -> PageDrawing {
        let none = PageDrawing(pictures: [], failed: false, partFailed: false)
        guard let matrix = state.pageMatrix(page) else { return none }
        let size = state.sizes[page]
        let ppp = state.scale * state.pixelsPerDip
        let version = state.versions[page]
        let tint = state.tint
        let preview = TilePlan.preview(page, version, tint, size)
        let previewOnly = ppp <= preview.key.scale
        let rect = state.layout.pageRect(page)
        let visible = ViewRect.intersect(ViewRect(rect.x - state.offsetX, rect.y - state.offsetY, rect.width, rect.height),
                                         ViewRect(0, 0, state.viewport.width, state.viewport.height))
        if visible.isEmpty { return none }
        let content = ViewRect(visible.x + state.offsetX, visible.y + state.offsetY, visible.width, visible.height)

        let complete = previewOnly
            ? cache.contains(preview.key)
            : state.required(page, content, { $0 }).allSatisfy { cache.contains($0.key) }
        func sharp(_ key: TileKey) -> Bool {
            key.version == version && (previewOnly ? key.isPreview : !key.isPreview && key.scale == ppp)
        }

        let keys = cache.keys(page).filter { $0.tint == tint && (!complete || sharp($0)) }
            .sorted { Self.rank($0, version, ppp) < Self.rank($1, version, ppp) }
        var pictures: [PagePicture] = []
        for key in keys {
            guard let picture = cache.peek(key) else { continue }
            let dest = Self.destination(key, picture, matrix, size)
            if !dest.intersectsWith(visible) { continue }
            _ = cache.get(key)
            pictures.append(PagePicture(picture: picture, rect: snapped(dest), isPreview: key.isPreview))
        }
        if complete {
            cache.removeWhere(page) { $0.tint != tint || $0.version != version || (!sharp($0) && !$0.isPreview) }
        }
        let previewFailed = failed.contains(preview.key)
        let partFailed = !previewFailed && failed.contains { $0.page == page && !$0.isPreview && $0.scale == ppp && $0.version == version }
        return PageDrawing(pictures: pictures, failed: !complete && previewFailed, partFailed: partFailed)
    }

    // Older pictures first, then the smaller ones, the current page's own preview, other zooms by how near they are, the sharp tiles last.
    private static func rank(_ key: TileKey, _ version: Int, _ ppp: Double) -> Double {
        let rank = key.version == version ? 1000.0 : 0
        if key.isPreview { return rank }
        return rank + 500 - abs(log(key.scale / ppp)) * 10
    }

    private static func destination(_ key: TileKey, _ picture: TilePicture, _ matrix: ViewMatrix, _ page: ViewSize) -> ViewRect {
        let points = key.isPreview
            ? ViewRect(0, 0, page.width, page.height)
            : TilePlan.pointsRect(TileSpec(key, key.column * TilePlan.tileSize, key.row * TilePlan.tileSize, 0, 0), picture.pixelWidth, picture.pixelHeight)
        return PageSpace.transform(matrix, points)
    }

    private func snapped(_ rect: ViewRect) -> ViewRect {
        let ppd = state.pixelsPerDip
        func snap(_ v: Double) -> Double { (v * ppd).rounded(.toNearestOrAwayFromZero) / ppd }
        return ViewRect(from: ViewPoint(snap(rect.left), snap(rect.top)), to: ViewPoint(snap(rect.right), snap(rect.bottom)))
    }

    public var layers: LayerSet {
        _ = layerRevision
        guard let tab else { return LayerSet(layers: [], order: []) }
        return PdfLayers.read(displaySession?.document ?? tab.document)
    }

    public func setLayerVisible(_ layer: PdfReference, _ visible: Bool) {
        guard let tab else { return }
        let inFile = PdfLayers.read(tab.document).layers.first { $0.reference == layer }?.isOn ?? visible
        if visible == inFile { layerChanges[layer] = nil } else { layerChanges[layer] = visible }
        Task { await rebuildDisplay() }
    }

    func resetLayers() {
        layerChanges.removeAll()
        layerTicket += 1
        drawer.use(tab?.canDraw == true ? tab?.renderer : nil)
        dropDisplay()
    }

    // The file changed: the layers the person switched are switched again on the new state.
    func reapplyLayers() {
        if layerChanges.isEmpty { return }
        Task { await rebuildDisplay() }
    }

    private func dropDisplay() {
        displayRenderer?.close()
        displayRenderer = nil
        displaySession = nil
    }

    // The pages are drawn from the tab again, with new pictures.
    private func showTab() {
        drawer.use(tab?.canDraw == true ? tab?.renderer : nil)
        dropDisplay()
        state.renewVersions()
        failed.removeAll()
        layerRevision += 1
        scheduleTiles()
        onRedraw?()
    }

    private func rebuildDisplay() async {
        layerTicket += 1
        let ticket = layerTicket
        guard let tab else { return }
        if layerChanges.isEmpty {
            showTab()
            return
        }
        let read = readable(tab)
        let changes = layerChanges.map { (layer: $0.key, visible: $0.value) }
        let make = makeRenderer
        let copy = await Task.detached {
            let (data, password) = read()
            return DisplayCopy.create(data, password: password, changes: changes, makeRenderer: make)
        }.value
        if ticket != layerTicket {
            copy?.renderer.close()
            return
        }
        guard let copy else {
            // The pages were given new versions by the reload; showing them from the old copy would keep the edit out.
            showTab()
            return
        }
        let old = displayRenderer
        displaySession = copy.session
        displayRenderer = copy.renderer
        drawer.use(copy.renderer)
        old?.close()
        state.renewVersions()
        failed.removeAll()
        layerRevision += 1
        scheduleTiles()
        onRedraw?()
    }
}
