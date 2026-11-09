import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/EditSurface.cs: the pointer tool of the panel. It only reports what the person
// did; the panel makes the edits, so that it knows which of the document's changes are its own. What it draws on the pages
// is in EditSurface+Chrome.swift.

/// What the pointer does on the pages.
public enum EditMode {
    /// Click an object, drag to move it or to select several, drag a handle to resize.
    case select
    /// Drag the box of a new text.
    case textBox
    /// Drag the area of a new link, or click one to change it.
    case link
    /// Drag the part of the selected picture to keep.
    case crop
}

@MainActor
final class EditSurface: PagePointerTool {
    enum Gesture {
        case none, band, move, resize
    }

    // Screen points: how far the pointer goes before a press is a drag, how near a handle or an object it has to be for a
    // finger to find it, and the smallest box a resize leaves.
    static let slop = 4.0
    static let reach = 24.0
    static let objectReach = 12.0
    static let minSize = 2.0

    let viewer: DocumentViewer
    let edits: ContentEdits

    var chromePages = Set<Int>()
    private(set) var selected: [Int] = []
    var mode: EditMode = .select
    var gesture: Gesture = .none
    var gesturePage = 0
    var start = ViewPoint.zero
    var now = ViewPoint.zero
    var origin = ViewRect.empty
    var handle = 0
    var moved = false
    var square = false
    var areaPage = -1
    var area = ViewRect.empty
    var activeLink: PdfReference? {
        didSet { redrawAll() }
    }
    var linkCache: [Int: [PdfLink]] = [:]
    private var extend = false
    private var pressed: PageObject?
    private var pressedLink: PdfLink?

    /// The page of the selection, or -1.
    private(set) var page = -1

    /// A press is about to start something; the panel finishes what it had open first.
    var onPressing: (() -> Void)?
    var onSelectionChanged: (() -> Void)?

    /// A click on text: the page, the object and the place in page space.
    var onTextClicked: ((Int, Int, ViewPoint) -> Void)?

    /// An area was dragged in the text box, link or crop mode; in user space.
    var onAreaDrawn: ((Int, PdfRect) -> Void)?
    var onLinkPicked: ((Int, PdfLink) -> Void)?
    var onMoveRequested: ((Int, [Int], Double, Double) -> Void)?
    var onResizeRequested: ((Int, [Int], PdfRect) -> Void)?
    var onKey: ((ViewerKey) -> Bool)?

    init(_ viewer: DocumentViewer, _ edits: ContentEdits) {
        self.viewer = viewer
        self.edits = edits
    }

    var cursor: PointerCursor? { mode == .select ? nil : .crosshair }

    /// The surface has the pointer; the viewer's Hand and Select buttons take it away.
    var isActive: Bool { viewer.pointerTool === self }

    func attach() {
        viewer.pointerTool = self
    }

    func setMode(_ new: EditMode) {
        if mode == new { return }
        mode = new
        gesture = .none
        showArea(-1, nil)
        redrawAll()
    }

    func select(_ page: Int, _ ids: [Int]) {
        let old = self.page
        selected = ids
        self.page = ids.isEmpty ? -1 : page
        redraw(old)
        redraw(self.page)
        onSelectionChanged?()
    }

    func clear() {
        select(-1, [])
    }

    /// The document changed: drops ids that are gone and draws again.
    func refresh() {
        linkCache = [:]
        if page >= 0 { selected.removeAll { edits.object(page, $0) == nil } }
        if selected.isEmpty { page = -1 }
        redrawAll()
        onSelectionChanged?()
    }

    // MARK: Pointer

    func takes(_ pointer: PagePointer) -> Bool {
        guard mode == .select else { return true }
        if !selected.isEmpty, pointer.page == page {
            let bounds = selectionBounds()
            if Self.handleIndex(at: pointer.point, of: bounds, scale: scale(pointer.page)) >= 0 || bounds.contains(pointer.point) { return true }
        }
        return hit(pointer.page, pointer.point) != nil
    }

    func key(_ key: ViewerKey, modifiers: PointerModifiers) -> Bool {
        onKey?(key) ?? false
    }

    func press(_ p: PagePointer) {
        onPressing?()
        gesturePage = p.page
        start = p.point
        now = p.point
        moved = false
        pressed = nil
        pressedLink = nil
        gesture = .band
        if mode == .link {
            pressedLink = link(at: p.page, p.point)
            return
        }
        if mode != .select { return }

        let shift = p.modifiers.contains(.shift)
        extend = shift
        if !selected.isEmpty && p.page == page {
            let bounds = selectionBounds()
            let grabbed = Self.handleIndex(at: p.point, of: bounds, scale: scale(p.page))
            if grabbed >= 0 {
                gesture = .resize
                handle = grabbed
                origin = bounds
                return
            }
            if !shift && bounds.contains(p.point) {
                gesture = .move
                pressed = hit(p.page, p.point)
                return
            }
        }
        guard let found = hit(p.page, p.point) else {
            if !shift { clear() }
            return
        }
        if shift && p.page == page {
            if let at = selected.firstIndex(of: found.id) { selected.remove(at: at) } else { selected.append(found.id) }
            select(p.page, selected)
        } else {
            select(p.page, [found.id])
        }
        gesture = .move
        pressed = found
    }

    func move(_ p: PagePointer) {
        guard p.pressed, gesture != .none, p.page == gesturePage else { return }
        now = p.point
        square = !p.modifiers.contains(.shift)
        if !moved && distance(start, now) * scale(p.page) > Self.slop { moved = true }
        redraw(gesturePage)
    }

    func release(_ p: PagePointer) {
        let finished = gesture
        gesture = .none
        if p.page == gesturePage { now = p.point }
        let page = gesturePage
        switch finished {
        case .band:
            finishBand(page)
        case .move where !moved:
            if !extend, let text = pressed as? TextObject { onTextClicked?(page, text.id, start) }
        case .move:
            let geometry = viewer.geometry(page)
            let from = geometry.toUser(start.x, start.y)
            let to = geometry.toUser(now.x, now.y)
            onMoveRequested?(page, selected, to.x - from.x, to.y - from.y)
        case .resize where moved:
            onResizeRequested?(page, selected, userRect(page, resized()))
        default:
            break
        }
        redraw(page)
    }

    func cancel() {
        gesture = .none
        redrawAll()
    }

    /// Leaves the pages as they were.
    func detach() {
        gesture = .none
        selected = []
        page = -1
        if viewer.pointerTool === self { viewer.pointerTool = nil }
        removeChrome()
    }

    private func finishBand(_ page: Int) {
        if mode == .link, !moved, let link = pressedLink {
            onLinkPicked?(page, link)
            return
        }
        if !moved { return }
        let size = viewer.pageSize(page)
        let band = ViewRect.intersect(ViewRect(from: start, to: now), ViewRect(0, 0, size.width, size.height))
        if band.isEmpty { return }
        if mode == .select {
            let found = ((try? edits.editor(page).select(userRect(page, band))) ?? [])
                .filter { !isBackdrop(page, $0) }
                .map(\.id)
            select(page, found)
        } else if band.width >= 6 && band.height >= 6 {
            onAreaDrawn?(page, userRect(page, band))
        }
    }

    // MARK: Hit testing

    func scale(_ page: Int) -> Double {
        let scale = viewer.pageToView(page).map { ViewScale.of($0) } ?? viewer.zoom
        return scale > 0.01 ? scale : 1
    }

    func hit(_ page: Int, _ at: ViewPoint) -> PageObject? {
        let (x, y) = viewer.geometry(page).toUser(at.x, at.y)
        guard let found = try? edits.editor(page).hitTest(x, y, Self.objectReach / scale(page)) else { return nil }
        return isBackdrop(page, found) ? nil : found
    }

    // A path as big as the page is its background; grabbing it by mistake would carry the whole page along.
    private func isBackdrop(_ page: Int, _ o: PageObject) -> Bool {
        let size = viewer.pageSize(page)
        return o is PathObject && o.bounds.width * o.bounds.height >= 0.8 * size.width * size.height
    }

    func links(_ page: Int) -> [PdfLink] {
        if let known = linkCache[page] { return known }
        let read = page >= 0 && page < viewer.pageCount ? edits.links(page) : []
        linkCache[page] = read
        return read
    }

    private func link(at page: Int, _ point: ViewPoint) -> PdfLink? {
        let (x, y) = viewer.geometry(page).toUser(point.x, point.y)
        let slop = Self.reach / 2 / scale(page)
        return links(page).last { x >= $0.rect.left - slop && x <= $0.rect.right + slop && y >= $0.rect.bottom - slop && y <= $0.rect.top + slop }
    }

    func pageRect(_ page: Int, _ user: PdfRect) -> ViewRect {
        let d = viewer.geometry(page).toDisplay(user)
        return ViewRect(d.x, d.y, d.width, d.height)
    }

    private func userRect(_ page: Int, _ shown: ViewRect) -> PdfRect {
        viewer.geometry(page).toUser(DisplayRect(shown.x, shown.y, shown.width, shown.height))
    }

    func selectionBounds() -> ViewRect {
        var bounds = ViewRect.empty
        for id in selected {
            if let o = edits.object(page, id) { bounds = Self.union(bounds, pageRect(page, o.bounds)) }
        }
        return bounds
    }

    func distance(_ a: ViewPoint, _ b: ViewPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    static func union(_ a: ViewRect, _ b: ViewRect) -> ViewRect {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let left = Swift.min(a.left, b.left), top = Swift.min(a.top, b.top)
        return ViewRect(left, top, Swift.max(a.right, b.right) - left, Swift.max(a.bottom, b.bottom) - top)
    }

    // MARK: Handles

    // The handles run round the box from the top left: corners at 0, 2, 4, 6 and sides at 1, 3, 5, 7.
    static func handles(_ r: ViewRect) -> [ViewPoint] {
        [
            ViewPoint(r.left, r.top), ViewPoint(r.x + r.width / 2, r.top), ViewPoint(r.right, r.top),
            ViewPoint(r.right, r.y + r.height / 2), ViewPoint(r.right, r.bottom), ViewPoint(r.x + r.width / 2, r.bottom),
            ViewPoint(r.left, r.bottom), ViewPoint(r.left, r.y + r.height / 2),
        ]
    }

    /// The handle nearest `at` within reach, else -1. The reach is a fingertip's, but never more than a third of the box, so
    /// that a small picture can still be grabbed by its middle.
    static func handleIndex(at: ViewPoint, of bounds: ViewRect, scale: Double) -> Int {
        let reach = Swift.max(8, Swift.min(Self.reach, Swift.min(bounds.width, bounds.height) * scale / 3))
        var best = -1
        var bestDistance = Double.infinity
        for (i, h) in handles(bounds).enumerated() {
            let dx = abs(h.x - at.x) * scale, dy = abs(h.y - at.y) * scale
            if dx <= reach && dy <= reach && dx + dy < bestDistance {
                best = i
                bestDistance = dx + dy
            }
        }
        return best
    }

    func resized() -> ViewRect {
        Self.resize(origin, handle, now, square: square)
    }

    // The box with the dragged handle at the pointer and the opposite side held; corners keep the proportions when asked.
    static func resize(_ origin: ViewRect, _ handle: Int, _ now: ViewPoint, square: Bool) -> ViewRect {
        var left = origin.left, top = origin.top, right = origin.right, bottom = origin.bottom
        if handle == 0 || handle == 6 || handle == 7 { left = Swift.min(now.x, right - minSize) }
        if handle == 2 || handle == 3 || handle == 4 { right = Swift.max(now.x, left + minSize) }
        if handle == 0 || handle == 1 || handle == 2 { top = Swift.min(now.y, bottom - minSize) }
        if handle == 4 || handle == 5 || handle == 6 { bottom = Swift.max(now.y, top + minSize) }
        if handle % 2 == 0 && square {
            let width = right - left
            let height = width * origin.height / origin.width
            if handle == 0 || handle == 2 { top = bottom - height } else { bottom = top + height }
        }
        return ViewRect(from: ViewPoint(left, top), to: ViewPoint(right, bottom))
    }
}
