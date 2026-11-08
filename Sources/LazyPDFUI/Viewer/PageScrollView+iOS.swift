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
                                failure: UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor)
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
    private var scrollingByFinger = false
    private var lastTouch = ViewPoint.zero
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
        for recognizer in [pinch, twice, once, hold, tool] as [UIGestureRecognizer] {
            recognizer.delegate = self
            scroll.addGestureRecognizer(recognizer)
        }

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

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if let press = recognizer as? UILongPressGestureRecognizer {
            return press.minimumPressDuration == 0 ? viewer.pointerTool != nil : viewer.pointerTool == nil && viewer.mode == .select
        }
        if recognizer is UITapGestureRecognizer { return viewer.pointerTool == nil }
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
        scroll.panGestureRecognizer.minimumNumberOfTouches = viewer.pointerTool == nil ? 1 : 2
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
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

    // A pointer tool takes one finger from the scroll view, except where it says it has no use for it: there the finger
    // scrolls the page by hand, since the scroll view's own pan waits for two.
    @objc private func toolTouched(_ recognizer: UILongPressGestureRecognizer) {
        let at = viewPoint(recognizer)
        switch recognizer.state {
        case .began:
            // A field open on the page keeps what was typed when the finger lands somewhere else.
            endEditing(true)
            scrollingByFinger = !viewer.toolTakes(at)
            lastTouch = at
            if !scrollingByFinger { viewer.pointerDown(at, touch: true) }
        case .changed:
            if scrollingByFinger {
                viewer.scroll(by: lastTouch.x - at.x, lastTouch.y - at.y)
                lastTouch = at
            } else {
                viewer.pointerMove(at)
            }
        case .ended:
            if !scrollingByFinger { viewer.pointerUp(at) }
            scrollingByFinger = false
        default:
            if !scrollingByFinger { viewer.pointerCancel() }
            scrollingByFinger = false
        }
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
        let copy = UIAction(title: L10n.t("Copy")) { [viewer] _ in
            Task { @MainActor in
                if let text = await viewer.selectedText() { UIPasteboard.general.string = text }
            }
        }
        return UIMenu(children: [copy])
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
