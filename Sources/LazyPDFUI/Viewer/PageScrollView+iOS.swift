#if canImport(SwiftUI)
#if os(iOS)
import SwiftUI
import UIKit
import LazyPDFApp
import LazyPDFKit

// The iPhone and iPad twin of windows/LazyPDF.App/Viewer/PageSurface.cs: a UIScrollView that only holds the scroll position and
// the size, with the pages drawn by a view behind it that is always the size of the screen (a view as tall as the pages would
// not fit in memory). The pinch goes to the model, not to the scroll view's zoom, so tiles are drawn again at the new scale.

final class PageCanvasView: UIView {
    let viewer: ViewerModel

    init(viewer: ViewerModel) {
        self.viewer = viewer
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("PageCanvasView is made in code")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let colors = PageColors(edge: UIColor.separator.resolvedColor(with: traitCollection).cgColor,
                                selection: tintColor.withAlphaComponent(0.35).cgColor, mark: tintColor.cgColor,
                                failure: UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor, showsHandles: true)
        PagePainter.draw(viewer, in: context, dirty: rect, colors: colors)
    }
}

final class PageScrollView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    let viewer: ViewerModel
    let canvas: PageCanvasView
    let scroll = UIScrollView()
    private var syncing = false
    private var lastScale: CGFloat = 1
    private var selecting = false
    private var editMenu: UIEditMenuInteraction?
    private lazy var fields = OverlayFieldViews(viewer: viewer, host: self)
    private let toolPress = UILongPressGestureRecognizer()
    private let handlePan = UIPanGestureRecognizer()
    private var handleDragging = false
    private var scrollingByFinger = false
    private var caughtGlide = false
    private var lastTouch = ViewPoint.zero
    private var touchStart = ViewPoint.zero
    private var samples: [(time: Double, point: ViewPoint)] = []
    private var glide: CADisplayLink?
    private var glideMomentum: Momentum?
    private var glideTime = 0.0
    private var keyboardInset: CGFloat = 0

    init(viewer: ViewerModel) {
        self.viewer = viewer
        canvas = PageCanvasView(viewer: viewer)
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        addSubview(canvas)
        addSubview(scroll)
        scroll.delegate = self
        scroll.backgroundColor = .clear
        scroll.alwaysBounceVertical = false
        scroll.showsHorizontalScrollIndicator = true
        scroll.isAccessibilityElement = false

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let twice = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        twice.numberOfTapsRequired = 2
        let once = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        once.require(toFail: twice)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        let tool = toolPress
        tool.addTarget(self, action: #selector(toolTouched(_:)))
        tool.minimumPressDuration = 0
        tool.allowableMovement = .greatestFiniteMagnitude
        tool.numberOfTouchesRequired = 1
        let handle = handlePan
        handle.addTarget(self, action: #selector(handleMoved(_:)))
        handle.maximumNumberOfTouches = 1
        for recognizer in [pinch, twice, once, hold, tool, handle] as [UIGestureRecognizer] {
            recognizer.delegate = self
            scroll.addGestureRecognizer(recognizer)
        }
        scroll.panGestureRecognizer.require(toFail: handle)

        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu

        viewer.onScroll = { [weak self] in self?.follow() }
        viewer.onRedraw = { [weak self] in
            self?.canvas.setNeedsDisplay()
            self?.fields.sync()
        }
        viewer.onToolChange = { [weak self] in self?.toolChanged() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardMoved(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardGone), name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardSettled), name: UIResponder.keyboardDidShowNotification, object: nil)
        toolChanged()
        follow()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("PageScrollView is made in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        scroll.frame = bounds
        viewer.setScreen(viewport: ViewSize(bounds.width, Swift.max(bounds.height - keyboardInset, 1)), pixelsPerDip: Double(window?.screen.scale ?? traitCollection.displayScale))
    }

    override var canBecomeFirstResponder: Bool { true }

    // The model moved the pages or changed their size: the scroll view goes along.
    private func follow() {
        let extent = viewer.extent
        let size = CGSize(width: extent.width, height: extent.height)
        syncing = true
        defer { syncing = false }
        if scroll.contentSize != size { scroll.contentSize = size }
        let offset = viewer.offset
        if abs(scroll.contentOffset.x - offset.x) > 0.001 || abs(scroll.contentOffset.y - offset.y) > 0.001 {
            scroll.contentOffset = CGPoint(x: offset.x, y: offset.y)
        }
        fields.sync()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if syncing { return }
        viewer.scrollTo(x: scrollView.contentOffset.x, y: scrollView.contentOffset.y)
    }

    private func viewPoint(_ recognizer: UIGestureRecognizer) -> ViewPoint {
        // The scroll view's own touches are in its content, which is the view moved by the offset.
        let point = recognizer.location(in: self)
        return ViewPoint(point.x, point.y)
    }

    // Where the finger first touched, since a pan reports its position only after it has moved off.
    private func touchDown(_ recognizer: UIPanGestureRecognizer) -> ViewPoint {
        let at = viewPoint(recognizer)
        let moved = recognizer.translation(in: self)
        return ViewPoint(at.x - moved.x, at.y - moved.y)
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if let press = recognizer as? UILongPressGestureRecognizer {
            if press.minimumPressDuration == 0 { return viewer.pointerTool != nil }
            // A finger resting on a handle is about to drag it, not to select a word.
            return viewer.pointerTool == nil && viewer.mode == .select && viewer.handle(at: viewPoint(recognizer), within: 24) == nil
        }
        if recognizer is UITapGestureRecognizer { return viewer.pointerTool == nil }
        if recognizer === handlePan { return viewer.handle(at: touchDown(handlePan), within: 24) != nil }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if recognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer { return true }
        // Two fingers scroll while the first still holds the tool's press, which the scroll then cancels.
        let pan = scroll.panGestureRecognizer
        return viewer.pointerTool != nil && (recognizer === pan || other === pan)
    }

    // One finger belongs to a pointer tool, so the scroll view's own pan needs two while one is set.
    private func toolChanged() {
        stopGlide()
        scroll.panGestureRecognizer.minimumNumberOfTouches = viewer.pointerTool == nil ? 1 : 2
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stopGlide()
        cancelToolTouch()
    }

    private func cancelToolTouch() {
        guard viewer.pointerTool != nil else { return }
        viewer.pointerCancel()
        scrollingByFinger = false
        toolPress.isEnabled = false
        toolPress.isEnabled = true
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            stopGlide()
            cancelToolTouch()
            lastScale = 1
        case .changed:
            viewer.magnify(by: recognizer.scale / lastScale, about: viewPoint(recognizer))
            lastScale = recognizer.scale
        default:
            break
        }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        viewer.toggleZoom(about: viewPoint(recognizer))
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        becomeFirstResponder()
        endEditing(true)
        let at = viewPoint(recognizer)
        viewer.pointerDown(at, touch: true)
        viewer.pointerUp(at)
    }

    // A long press selects the word under the finger, and dragging on grows the selection; lifting offers Copy.
    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        let at = viewPoint(recognizer)
        switch recognizer.state {
        case .began:
            viewer.pointerDown(at, clicks: 2, touch: true)
            selecting = true
        case .changed:
            if selecting { viewer.pointerMove(at) }
        case .ended:
            guard selecting else { return }
            selecting = false
            viewer.pointerUp(at)
            if viewer.hasSelection {
                editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: at.x, y: at.y)))
            }
        default:
            if selecting { viewer.pointerCancel() }
            selecting = false
        }
    }

    // Dragging a handle of the selection moves that end; the edit menu is out of the way meanwhile and comes back where it ends.
    @objc private func handleMoved(_ recognizer: UIPanGestureRecognizer) {
        let at = viewPoint(recognizer)
        switch recognizer.state {
        case .began:
            let down = touchDown(recognizer)
            guard let start = viewer.handle(at: down, within: .infinity) else { return }
            handleDragging = true
            editMenu?.dismissMenu()
            viewer.beginHandleDrag(start: start, at: down)
        case .changed:
            if handleDragging { viewer.pointerMove(at) }
        case .ended:
            guard handleDragging else { return }
            handleDragging = false
            viewer.pointerUp(at)
            if viewer.hasSelection {
                editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: at.x, y: at.y)))
            }
        default:
            if handleDragging { viewer.pointerCancel() }
            handleDragging = false
        }
    }

    // A pointer tool takes one finger from the scroll view, except where it says it has no use for it: there the finger
    // scrolls the page by hand, since the scroll view's own pan waits for two.
    @objc private func toolTouched(_ recognizer: UILongPressGestureRecognizer) {
        let at = viewPoint(recognizer)
        switch recognizer.state {
        case .began:
            // A field open on the page keeps what was typed when the finger lands somewhere else.
            endEditing(true)
            // A finger that lands on a gliding page only stops it, as on a system scroll view.
            caughtGlide = glide != nil
            stopGlide()
            scrollingByFinger = caughtGlide || !viewer.toolTakes(at)
            lastTouch = at
            touchStart = at
            samples = [(ProcessInfo.processInfo.systemUptime, at)]
            if !scrollingByFinger { viewer.pointerDown(at, touch: true) }
        case .changed:
            if scrollingByFinger {
                viewer.scroll(by: lastTouch.x - at.x, lastTouch.y - at.y)
                lastTouch = at
                samples.append((ProcessInfo.processInfo.systemUptime, at))
            } else {
                viewer.pointerMove(at)
            }
        case .ended:
            if !scrollingByFinger {
                viewer.pointerUp(at)
            } else if hypot(at.x - touchStart.x, at.y - touchStart.y) <= 4 {
                if !caughtGlide { viewer.followLink(at: at) }
            } else {
                startGlide()
            }
            scrollingByFinger = false
        default:
            if !scrollingByFinger { viewer.pointerCancel() }
            scrollingByFinger = false
        }
    }

    // The speed of the last two samples within 80 ms of each other, so a finger that rested before lifting does not throw the page.
    private func startGlide() {
        guard samples.count >= 2 else { return }
        let last = samples[samples.count - 1]
        let before = samples[samples.count - 2]
        let span = last.time - before.time
        guard span > 0, span <= 0.08, ProcessInfo.processInfo.systemUptime - last.time <= 0.08 else { return }
        glideMomentum = Momentum(velocity: ViewPoint((last.point.x - before.point.x) / span, (last.point.y - before.point.y) / span))
        guard glideMomentum != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(glided(_:)))
        glideTime = link.timestamp
        link.add(to: .main, forMode: .common)
        glide = link
    }

    private func stopGlide() {
        glide?.invalidate()
        glide = nil
        glideMomentum = nil
    }

    @objc private func glided(_ link: CADisplayLink) {
        let dt = glideTime == 0 ? link.targetTimestamp - link.timestamp : link.timestamp - glideTime
        glideTime = link.timestamp
        guard var momentum = glideMomentum, let delta = momentum.step(dt) else { return stopGlide() }
        glideMomentum = momentum
        let before = viewer.offset
        viewer.scroll(by: -delta.x, -delta.y, turns: false)
        if viewer.offset == before { stopGlide() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopGlide() }
    }

    @objc private func keyboardMoved(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let space = window?.screen.coordinateSpace else { return }
        let local = convert(end, from: space)
        keyboardInset = Swift.max(0, bounds.maxY - local.minY)
        setNeedsLayout()
    }

    @objc private func keyboardGone() {
        keyboardInset = 0
        setNeedsLayout()
    }

    // The field that took the focus may sit under the keyboard, or move when the view is refitted to what is left.
    @objc private func keyboardSettled() {
        layoutIfNeeded()
        fields.revealFocused()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let point = configuration.sourcePoint
        let copy = UIAction(title: L10n.t("Copy")) { [viewer] _ in
            Task { @MainActor in
                if let text = await viewer.selectedText() { UIPasteboard.general.string = text }
            }
        }
        let lookUp = UIAction(title: L10n.t("Look Up")) { [weak self] _ in
            Task { @MainActor in
                guard let self, let text = await self.viewer.selectedText() else { return }
                self.present(UIReferenceLibraryViewController(term: text))
            }
        }
        let share = UIAction(title: L10n.t("Share")) { [weak self] _ in
            Task { @MainActor in
                guard let self, let text = await self.viewer.selectedText() else { return }
                let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = self
                sheet.popoverPresentationController?.sourceRect = CGRect(origin: point, size: .zero)
                self.present(sheet)
            }
        }
        let selectAll = UIAction(title: L10n.t("Select all")) { [weak self] _ in
            self?.viewer.selectAll()
            DispatchQueue.main.async {
                self?.editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            }
        }
        return UIMenu(children: viewer.hasSelection ? [copy, lookUp, share, selectAll] : [copy, selectAll])
    }

    private func present(_ controller: UIViewController) {
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(controller, animated: true)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = presses
        for press in presses {
            guard let key = press.key, let mapped = Self.keys[key.keyCode] else { continue }
            var modifiers: PointerModifiers = []
            if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
            if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if viewer.key(mapped, modifiers: modifiers) { unhandled.remove(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private static let keys: [UIKeyboardHIDUsage: ViewerKey] = [
        .keyboardUpArrow: .up, .keyboardDownArrow: .down, .keyboardLeftArrow: .left, .keyboardRightArrow: .right,
        .keyboardPageUp: .pageUp, .keyboardPageDown: .pageDown, .keyboardHome: .home, .keyboardEnd: .end,
        .keyboardSpacebar: .space, .keyboardReturnOrEnter: .enter, .keyboardEscape: .escape,
        .keyboardDeleteForward: .delete, .keyboardDeleteOrBackspace: .backspace,
    ]

    // One element for each page in view, named by its place in the file and holding the page's text, read from the engine in
    // reading order so it does not depend on what is drawn.
    // The text views of open fields follow, so a person using VoiceOver can reach what is being typed.
    override var accessibilityElements: [Any]? {
        get {
            let pages = viewer.visiblePages.compactMap { page -> UIAccessibilityElement? in
                guard let matrix = viewer.pageToView(page) else { return nil }
                let size = viewer.pageSize(page)
                let area = PageSpace.transform(matrix, ViewRect(0, 0, size.width, size.height))
                let element = UIAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = L10n.t("Page {0} of {1}", page + 1, viewer.pageCount)
                element.accessibilityValue = viewer.pageText(page)
                element.accessibilityFrameInContainerSpace = CGRect(x: area.x, y: area.y, width: area.width, height: area.height)
                return element
            }
            return pages as [Any] + fields.views as [Any]
        }
        set {}
    }
}

struct PageScrollRepresentable: UIViewRepresentable {
    let viewer: ViewerModel

    func makeUIView(context: Context) -> PageScrollView {
        PageScrollView(viewer: viewer)
    }

    func updateUIView(_ view: PageScrollView, context: Context) {}
}
#endif
#endif
