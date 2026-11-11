#if canImport(SwiftUI)
#if os(macOS)
import AppKit
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The Mac twin of windows/LazyPDF.App/Viewer/PageSurface.cs and PageSurfacePeer.cs: an NSScrollView whose flipped document view
// is as big as the pages laid out and draws only the part in view. The scroll bars and the wheel are the scroll view's; the
// pinch goes to the model, not to the scroll view's magnification, so tiles are drawn again at the new scale.

/// The scrolled area. It draws through `PagePainter` in the viewer's view space, so the context is moved by the scroll offset.
final class PageDocumentView: NSView, NSMenuItemValidation {
    let viewer: ViewerModel
    private(set) lazy var fields = OverlayFieldViews(viewer: viewer, host: self)
    private var menuPoint = NSPoint.zero

    init(viewer: ViewerModel) {
        self.viewer = viewer
        super.init(frame: .zero)
        setAccessibilityLabel(L10n.t("Page viewer"))
    }

    required init?(coder: NSCoder) {
        fatalError("PageDocumentView is made in code")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let offset = viewer.offset
        let colors = PageColors(edge: NSColor.separatorColor.cgColor, selection: NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor,
                                mark: NSColor.controlAccentColor.cgColor, failure: NSColor.secondaryLabelColor.cgColor)
        context.translateBy(x: offset.x, y: offset.y)
        PagePainter.draw(viewer, in: context, dirty: dirtyRect.offsetBy(dx: -offset.x, dy: -offset.y), colors: colors)
    }

    private func viewPoint(_ event: NSEvent) -> ViewPoint {
        let point = convert(event.locationInWindow, from: nil)
        let offset = viewer.offset
        return ViewPoint(point.x - offset.x, point.y - offset.y)
    }

    private func modifiers(_ event: NSEvent) -> PointerModifiers {
        var found: PointerModifiers = []
        if event.modifierFlags.contains(.shift) { found.insert(.shift) }
        if event.modifierFlags.contains(.command) { found.insert(.command) }
        if event.modifierFlags.contains(.option) { found.insert(.option) }
        if event.modifierFlags.contains(.control) { found.insert(.control) }
        return found
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        viewer.pointerDown(viewPoint(event), clicks: Swift.min(Swift.max(event.clickCount, 1), 3), modifiers: modifiers(event))
        showCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        viewer.pointerMove(viewPoint(event), modifiers: modifiers(event))
        showCursor()
    }

    override func mouseUp(with event: NSEvent) {
        viewer.pointerUp(viewPoint(event), modifiers: modifiers(event))
        showCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        viewer.pointerMove(viewPoint(event), modifiers: modifiers(event))
        showCursor()
    }

    private func showCursor() {
        switch viewer.cursor {
        case nil, .arrow?: NSCursor.arrow.set()
        case .crosshair?: NSCursor.crosshair.set()
        case .text?: NSCursor.iBeam.set()
        case .link?: NSCursor.pointingHand.set()
        case .move?: (viewer.mode == .hand ? NSCursor.openHand : NSCursor.closedHand).set()
        }
    }

    override func keyDown(with event: NSEvent) {
        if let key = key(event), viewer.key(key, modifiers: modifiers(event)) { return }
        super.keyDown(with: event)
    }

    private func key(_ event: NSEvent) -> ViewerKey? {
        switch event.specialKey {
        case .upArrow?: return .up
        case .downArrow?: return .down
        case .leftArrow?: return .left
        case .rightArrow?: return .right
        case .pageUp?: return .pageUp
        case .pageDown?: return .pageDown
        case .home?: return .home
        case .end?: return .end
        case .carriageReturn?, .enter?: return .enter
        case .deleteForward?: return .delete
        case .delete?, .backspace?: return .backspace
        default: break
        }
        if event.keyCode == 53 { return .escape }
        return event.characters == " " ? .space : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.t("Copy"), action: #selector(copy(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t("Look Up"), action: #selector(lookUpSelection(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t("Share"), action: #selector(shareSelection(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t("Select all"), action: #selector(selectAll(_:)), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        menuPoint = convert(event.locationInWindow, from: nil)
        return menu
    }

    @objc func copy(_ sender: Any?) {
        Task { @MainActor in
            guard let text = await viewer.selectedText() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc private func lookUpSelection(_ sender: Any?) {
        Task { @MainActor in
            guard let text = await viewer.selectedText() else { return }
            showDefinition(for: NSAttributedString(string: text), at: menuPoint)
        }
    }

    @objc private func shareSelection(_ sender: Any?) {
        Task { @MainActor in
            guard let text = await viewer.selectedText() else { return }
            NSSharingServicePicker(items: [text]).show(relativeTo: NSRect(origin: menuPoint, size: .zero), of: self, preferredEdge: .minY)
        }
    }

    override func selectAll(_ sender: Any?) {
        viewer.selectAll()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(selectAll(_:)) ? viewer.tab != nil : viewer.hasSelection
    }

    // One element for each page in view, named by its place in the file and holding the page's text, read from the engine in
    // reading order so it does not depend on what is drawn.
    override func isAccessibilityElement() -> Bool { false }

    // The text views of open fields follow, so a person using VoiceOver can reach what is being typed.
    override func accessibilityChildren() -> [Any]? {
        let offset = viewer.offset
        let pages = viewer.visiblePages.compactMap { page -> NSAccessibilityElement? in
            guard let matrix = viewer.pageToView(page) else { return nil }
            let size = viewer.pageSize(page)
            let area = PageSpace.transform(matrix, ViewRect(0, 0, size.width, size.height))
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.group)
            element.setAccessibilityLabel(L10n.t("Page {0} of {1}", page + 1, viewer.pageCount))
            element.setAccessibilityValue(viewer.pageText(page))
            let local = NSRect(x: area.x + offset.x, y: area.y + offset.y, width: area.width, height: area.height)
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(local, to: nil)))
            }
            return element
        }
        return pages as [Any] + fields.views as [Any]
    }
}

final class PageScrollView: NSScrollView {
    let viewer: ViewerModel
    let pages: PageDocumentView
    private var syncing = false
    private var swipe = PageSwipe()

    init(viewer: ViewerModel) {
        self.viewer = viewer
        pages = PageDocumentView(viewer: viewer)
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        allowsMagnification = false
        documentView = pages
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification, object: contentView)
        viewer.redrawsOnScroll = false
        viewer.onScroll = { [weak self] in self?.follow() }
        viewer.onRedraw = { [weak self] in
            self?.pages.needsDisplay = true
            self?.pages.fields.sync()
        }
        follow()
    }

    required init?(coder: NSCoder) {
        fatalError("PageScrollView is made in code")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        giveScreen()
    }

    // The keys of the pages work as soon as a document is shown, without a click first.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.pages)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        giveScreen()
    }

    private func giveScreen() {
        let size = contentSize
        viewer.setScreen(viewport: ViewSize(size.width, size.height), pixelsPerDip: Double(window?.backingScaleFactor ?? 2))
    }

    @objc private func clipMoved() {
        if syncing { return }
        let origin = contentView.bounds.origin
        viewer.scrollTo(x: origin.x, y: origin.y)
    }

    // The model moved the pages or changed their size: the scroll view goes along.
    private func follow() {
        let extent = viewer.extent
        let size = NSSize(width: Swift.max(extent.width, 1), height: Swift.max(extent.height, 1))
        syncing = true
        defer { syncing = false }
        if pages.frame.size != size { pages.setFrameSize(size) }
        let offset = viewer.offset
        let origin = contentView.bounds.origin
        if abs(origin.x - offset.x) > 0.001 || abs(origin.y - offset.y) > 0.001 {
            contentView.scroll(to: NSPoint(x: offset.x, y: offset.y))
            reflectScrolledClipView(contentView)
        }
        pages.fields.sync()
    }

    // A paged layout turns the page when the wheel runs past the edge, which only the model knows about; momentum is left out
    // so one flick does not turn several pages.
    override func scrollWheel(with event: NSEvent) {
        if viewer.continuous {
            super.scrollWheel(with: event)
        } else if event.momentumPhase.isEmpty {
            // With nothing to scroll sideways, a two-finger swipe turns the page, as in Preview.
            if event.hasPreciseScrollingDeltas && viewer.extent.width <= viewer.viewport.width + 1,
               let step = swipe.add(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, began: event.phase == .began, ended: event.phase == .ended) {
                viewer.stepPage(step)
                return
            }
            // A wheel with notches reports lines; a trackpad reports points.
            let unit = event.hasPreciseScrollingDeltas ? 1 : PageSurfaceState.lineStep
            viewer.scroll(by: -event.scrollingDeltaX * unit, -event.scrollingDeltaY * unit, wheel: true)
        }
    }

    override func magnify(with event: NSEvent) {
        viewer.magnify(by: 1 + event.magnification, about: viewPoint(event))
    }

    override func smartMagnify(with event: NSEvent) {
        viewer.toggleZoom(about: viewPoint(event))
    }

    private func viewPoint(_ event: NSEvent) -> ViewPoint {
        let point = contentView.convert(event.locationInWindow, from: nil)
        let offset = viewer.offset
        return ViewPoint(point.x - offset.x, point.y - offset.y)
    }
}

struct PageScrollRepresentable: NSViewRepresentable {
    let viewer: ViewerModel

    func makeNSView(context: Context) -> PageScrollView {
        PageScrollView(viewer: viewer)
    }

    func updateNSView(_ view: PageScrollView, context: Context) {}
}
#endif
#endif
