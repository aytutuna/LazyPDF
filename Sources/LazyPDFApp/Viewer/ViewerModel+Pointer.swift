import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/PageViewer.Input.cs and PageViewer.Placement.cs: the pointer and the keyboard on the pages.
// Hand pans, Select selects text, a pointer tool takes the button from both where it says it has a use for the press; a click on
// a link follows it in either mode.
// Points are in the viewer's view (the area the pages show in, y down).

/// A key the pages answer to.
public enum ViewerKey {
    case up, down, left, right, pageUp, pageDown, space, home, end, enter, escape, delete, backspace
}

extension ViewerModel {
    private static let clickSlop = 4.0

    /// A finger (`touch`) is never hovering, so the tool hears no moves between its presses.
    public func pointerDown(_ at: ViewPoint, clicks: Int = 1, modifiers: PointerModifiers = [], touch: Bool = false) {
        touching = touch
        guard tab != nil else { return }
        let hit = state.hit(at)
        down = at
        last = at
        moved = false
        downLink = hit.flatMap { link(at: $0.page, $0.point) }
        if let tool, let over = hit, tool.takes(pointer(over.page, over.point, at, clicks, true, modifiers)) {
            drag = .tool
            dragPage = over.page
            tool.press(pointer(over.page, over.point, at, clicks, true, modifiers))
        } else if pointerMode == .hand {
            drag = .pan
            cursor = .move
        } else {
            drag = .select
            beginSelection(at, clicks: clicks, extend: modifiers.contains(.shift))
            startAutoScroll()
        }
    }

    public func pointerMove(_ at: ViewPoint, modifiers: PointerModifiers = []) {
        if drag != .none, hypot(at.x - down.x, at.y - down.y) > Self.clickSlop { moved = true }
        switch drag {
        case .pan:
            apply(state.scrollBy(last.x - at.x, last.y - at.y))
        case .select:
            dragSelection(at)
        case .tool:
            if let matrix = state.pageMatrix(dragPage) {
                tool?.move(pointer(dragPage, matrix.inverted().transform(at), at, 0, true, modifiers))
            }
        case .none:
            hover(at, modifiers)
        }
        last = at
    }

    public func pointerUp(_ at: ViewPoint, modifiers: PointerModifiers = []) {
        let was = drag
        if was == .tool {
            if let matrix = state.pageMatrix(dragPage) {
                tool?.release(pointer(dragPage, matrix.inverted().transform(at), at, 0, false, modifiers))
            } else {
                // The page the press began on is no longer laid out, so there is no place to release at.
                tool?.cancel()
            }
        }
        endDrag()
        if was == .pan || was == .select, !moved, let link = downLink { followLink(link) }
        hover(at, modifiers)
        touching = false
    }

    /// A tap the tool did not take still follows a link under it.
    public func followLink(at: ViewPoint) {
        guard let hit = state.hit(at), let target = link(at: hit.page, hit.point) else { return }
        followLink(target)
    }

    /// Whether the tool wants a finger that lands at `at`; false over no page or with no tool.
    public func toolTakes(_ at: ViewPoint) -> Bool {
        guard let tool, let over = state.hit(at) else { return false }
        return tool.takes(pointer(over.page, over.point, at, 1, true, []))
    }

    /// The pointer was taken away while the button was down (another window, a popup): the tool gets no release.
    public func pointerCancel() {
        if drag == .tool { tool?.cancel() }
        endDrag()
        touching = false
    }

    private func pointer(_ page: Int, _ point: ViewPoint, _ view: ViewPoint, _ clicks: Int, _ pressed: Bool, _ modifiers: PointerModifiers) -> PagePointer {
        PagePointer(page: page, point: point, view: view, pressed: pressed, clicks: clicks, modifiers: modifiers)
    }

    private func endDrag() {
        drag = .none
        anchorWaiting = nil
        autoScroll?.cancel()
        autoScroll = nil
    }

    // The cursor over what is under the pointer: a link, text to select, or the tool's own.
    private func hover(_ at: ViewPoint, _ modifiers: PointerModifiers) {
        if touching { return }
        if let tool {
            cursor = tool.cursor
            if let over = state.hit(at), state.pageMatrix(over.page) != nil {
                tool.move(pointer(over.page, over.point, at, 0, false, modifiers))
            }
            return
        }
        let hit = state.hit(at)
        if let hit, link(at: hit.page, hit.point) != nil {
            cursor = .link
        } else if pointerMode == .hand {
            cursor = .move
        } else {
            cursor = hit.map { isOverText($0.page, $0.point) } == true ? .text : nil
        }
    }

    private func startAutoScroll() {
        autoScroll?.cancel()
        autoScroll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard let self, self.drag == .select else { return }
                self.autoScrollStep()
            }
        }
    }

    // Selecting past the edge of the view scrolls on, faster the farther out the pointer is.
    func autoScrollStep() {
        let at = last
        let view = state.viewport
        let dy = at.y < 0 ? at.y : at.y > view.height ? at.y - view.height : 0
        let dx = at.x < 0 ? at.x : at.x > view.width ? at.x - view.width : 0
        if dx == 0 && dy == 0 { return }
        apply(state.scrollBy(dx / 3, dy / 3))
        dragSelection(at)
    }

    /// A key on the pages. False when the viewer has no use for it.
    @discardableResult
    public func key(_ key: ViewerKey, modifiers: PointerModifiers = []) -> Bool {
        if let tool, tool.key(key, modifiers: modifiers) { return true }
        if placeWithKeys(key, modifiers) { return true }
        let shift = modifiers.contains(.shift)
        let big = !modifiers.isDisjoint(with: [.command, .option, .control])
        if shift && !selected.isEmpty && extendSelection(key, big: big) { return true }
        let flips = !state.continuous && state.extent.width <= state.viewport.width + 1
        switch key {
        case .up: scroll(by: 0, -PageSurfaceState.lineStep)
        case .down: scroll(by: 0, PageSurfaceState.lineStep)
        case .left where flips: stepPage(-1)
        case .right where flips: stepPage(1)
        case .left: scroll(by: -PageSurfaceState.lineStep, 0)
        case .right: scroll(by: PageSurfaceState.lineStep, 0)
        case .pageUp: pageUp()
        case .pageDown: pageDown()
        case .space: scroll(by: 0, (shift ? -1 : 1) * state.pageStep)
        case .home: goToPage(0)
        case .end: goToPage(state.pageCount - 1)
        case .escape:
            if drag == .tool {
                drag = .none
                tool?.cancel()
            } else if findVisible {
                hideFind()
            } else if readingMode {
                readingMode = false
            } else {
                clearSelection()
            }
        case .enter, .delete, .backspace: return false
        }
        return true
    }

    public func pageUp() {
        scroll(by: 0, -state.pageStep)
    }

    public func pageDown() {
        scroll(by: 0, state.pageStep)
    }

    public func firstPage() {
        goToPage(0)
    }

    public func lastPage() {
        goToPage(state.pageCount - 1)
    }

    public func zoomIn() {
        apply(state.setZoom(ZoomMath.step(state.zoom, 1)))
    }

    public func zoomOut() {
        apply(state.setZoom(ZoomMath.step(state.zoom, -1)))
    }

    public func actualSize() {
        apply(state.setZoom(1))
    }

    public func fitWidth() {
        apply(state.setFit(.width))
    }

    public func fitPage() {
        apply(state.setFit(.page))
    }

    // Enter shows a cross in the middle of the page in view, the arrow keys move it (small steps with Shift, big ones with
    // Control or Command), and Enter again is a click there. Escape lets go.
    func placeWithKeys(_ key: ViewerKey, _ modifiers: PointerModifiers = []) -> Bool {
        guard let tool, tab != nil, drag == .none else { return false }
        guard var current = placement else {
            guard key == .enter, let start = KeyPlacement(state) else { return false }
            placement = start
            return true
        }
        guard let matrix = state.pageMatrix(current.page) else {
            endPlacement()
            return false
        }
        switch key {
        case .enter:
            let (page, at) = (current.page, current.point)
            let view = matrix.transform(at)
            endPlacement()
            tool.press(PagePointer(page: page, point: at, view: view, pressed: true, clicks: 1, modifiers: modifiers, fromKeys: true))
            tool.release(PagePointer(page: page, point: at, view: view, pressed: false, clicks: 0, modifiers: modifiers, fromKeys: true))
        case .escape:
            endPlacement()
        case .left, .right, .up, .down:
            let pace: KeyPlacement.Pace = modifiers.contains(.shift) ? .small : modifiers.isDisjoint(with: [.control, .command]) ? .normal : .big
            let direction: KeyPlacement.Direction = key == .left ? .left : key == .right ? .right : key == .up ? .up : .down
            _ = current.move(direction, pace, state)
            placement = current
        default:
            return false
        }
        return true
    }

    func endPlacement() {
        placement = nil
    }
}
