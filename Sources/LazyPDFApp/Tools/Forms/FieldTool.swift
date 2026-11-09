import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FieldTool.cs: the pointer while fields are edited. A press on a field selects it and a
// drag moves it, a drag from a handle of the selected field resizes it, and a drag on an empty place draws a new field of the
// chosen kind. A finger that lands where the tool has nothing to do scrolls the page, unless a kind is chosen to draw.

@MainActor
final class FieldTool: PagePointerTool {
    private static let minSize = 4.0
    private static let ghost = "forms.ghost"

    private enum Drag {
        case none, draw, move, size
    }

    private weak var model: FormsModel?
    private var drag = Drag.none
    private var page = 0
    private var handle = 0
    private var start = ViewPoint.zero
    private var origin = ViewRect(0, 0, 0, 0)
    private var box = ViewRect(0, 0, 0, 0)
    private var ghostPage: Int?

    init(_ model: FormsModel) {
        self.model = model
    }

    var cursor: PointerCursor? { .crosshair }

    func takes(_ pointer: PagePointer) -> Bool {
        guard let model else { return false }
        if model.newKind != nil { return true }
        return handleAt(model, pointer.page, pointer.point) != nil || model.widgetAt(pointer.page, pointer.point, near: true) != nil
    }

    func press(_ pointer: PagePointer) {
        guard let model else { return }
        page = pointer.page
        start = pointer.point
        if let selected = model.selectedBox(), selected.page == page, let found = handleAt(model, page, start) {
            begin(.size, selected.box)
            handle = found
        } else if let hit = model.widgetAt(page, start, near: model.newKind == nil) {
            model.select(hit.name, hit.index, hit.ordinal)
            begin(.move, hit.box)
        } else if model.newKind != nil {
            // Drawing keeps the selection, so a radio button drawn next to a selected group joins it.
            begin(.draw, ViewRect(from: start, to: start))
        } else {
            model.select(nil, 0, 0)
        }
    }

    func move(_ pointer: PagePointer) {
        guard drag != .none, let model, pointer.page == page else { return }
        let size = model.view.pageSize(page)
        let p = ViewPoint(min(max(pointer.point.x, 0), size.width), min(max(pointer.point.y, 0), size.height))
        switch drag {
        case .draw: box = ViewRect(from: start, to: p)
        case .move: box = ViewRect(origin.x + p.x - start.x, origin.y + p.y - start.y, origin.width, origin.height)
        default: box = resized(p)
        }
        showGhost()
    }

    func release(_ pointer: PagePointer) {
        move(pointer)
        let done = drag
        var finished = box
        cancel()
        guard let model else { return }
        switch done {
        case .draw:
            guard let kind = model.newKind else { return }
            if finished.width < Self.minSize && finished.height < Self.minSize {
                let (w, h) = FormEdits.defaultSize(kind)
                finished = ViewRect(start.x, start.y, w, h)
            }
            model.draw(page, finished)
        case .move, .size:
            if finished != origin && finished.width >= Self.minSize && finished.height >= Self.minSize { model.reshape(page, finished) }
        case .none:
            break
        }
    }

    func cancel() {
        drag = .none
        if let ghostPage { model?.view.overlay(ghostPage).remove(Self.ghost) }
        ghostPage = nil
    }

    private func begin(_ kind: Drag, _ area: ViewRect) {
        drag = kind
        origin = area
        box = area
    }

    // The handles of a small field would swallow the field itself, so their reach is a third of its smaller side at most.
    private func handleAt(_ model: FormsModel, _ page: Int, _ point: ViewPoint) -> Int? {
        guard let selected = model.selectedBox(), selected.page == page else { return nil }
        let slop = model.slop(page)
        let reach = min(slop, max(7 / model.scale(page), min(selected.box.width, selected.box.height) / 3))
        return FieldFrames.handles(selected.box).firstIndex { abs($0.x - point.x) <= reach && abs($0.y - point.y) <= reach }
    }

    // The handles run clockwise from the top left corner: 0 1 2 across the top, 3 on the right, 4 5 6 across the bottom, 7 on the left.
    private func resized(_ p: ViewPoint) -> ViewRect {
        var left = origin.left, top = origin.top, right = origin.right, bottom = origin.bottom
        if [0, 6, 7].contains(handle) { left = p.x }
        if [2, 3, 4].contains(handle) { right = p.x }
        if [0, 1, 2].contains(handle) { top = p.y }
        if [4, 5, 6].contains(handle) { bottom = p.y }
        return ViewRect(from: ViewPoint(left, top), to: ViewPoint(right, bottom))
    }

    private func showGhost() {
        ghostPage = page
        model?.view.overlay(page).set(OverlayItem(Self.ghost, .rect(box), style: OverlayStyle(
            stroke: .accent, fill: OverlayColor.accent.opacity(0.18), lineWidth: 1.5, dash: [4, 3])))
    }
}
