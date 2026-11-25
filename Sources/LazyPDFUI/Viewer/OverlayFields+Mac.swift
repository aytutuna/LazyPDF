#if canImport(SwiftUI)
#if os(macOS)
import AppKit
import CoreText
import LazyPDFApp
import LazyPDFKit

// The Mac side of OverlayField: a text view over the page for each open field, in the document view's coordinates. The text
// stays upright when the view is turned; it is scaled with the zoom. The field ends when the view loses the keyboard, on
// Return (Command-Return for a field of several lines) and on Escape; Tab goes to the field's own `onTab` when it has one.
// The text view sits in a scroll view without scrollers, which is the view that is placed and sized: text past a frame held
// inside the page scrolls with the caret instead of being resized away.

final class FieldTextView: NSTextView {
    var field: OverlayField?

    /// What the page view holds: the scroll view around this one.
    @MainActor var outer: NSView { enclosingScrollView ?? self }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, let field, !field.multiline || event.modifierFlags.contains(.command) {
            field.commit(string)
        } else if event.keyCode == 53 {
            field?.drop()
        } else if event.keyCode == 48, let tab = field?.onTab {
            tab(event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { field?.commit(string, focusLost: true) }
        return resigned
    }
}

@MainActor
final class OverlayFieldViews: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
    private let viewer: ViewerModel
    private unowned let host: NSView
    private var shown: [ObjectIdentifier: FieldTextView] = [:]

    init(viewer: ViewerModel, host: NSView) {
        self.viewer = viewer
        self.host = host
    }

    /// The open text views, for the accessibility tree of the page view.
    var views: [NSView] { shown.values.map { $0.outer } }

    // Makes, moves and removes the text views to match the open fields.
    func sync() {
        let open = viewer.openFields
        let live = Set(open.map { ObjectIdentifier($0.field) })
        for (key, view) in shown where !live.contains(key) {
            shown[key] = nil
            view.field = nil
            view.outer.isHidden = true
            // The view may be the one that just gave up the keyboard; it leaves once that is over.
            DispatchQueue.main.async { view.outer.removeFromSuperview() }
        }
        for (page, field) in open {
            let key = ObjectIdentifier(field)
            let view = shown[key] ?? make(field, page)
            place(view, field, page)
        }
    }

    private func make(_ field: OverlayField, _ page: Int) -> FieldTextView {
        let view = FieldTextView(frame: .zero)
        view.field = field
        view.delegate = self
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 2
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: 1e7, height: 1e7)
        view.string = field.text
        view.setAccessibilityLabel(field.label)
        if field.secure { view.layoutManager?.delegate = self }
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.documentView = view
        shown[ObjectIdentifier(field)] = view
        host.addSubview(scroll)
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, let field = view.field else { return }
            view.window?.makeFirstResponder(view)
            self.placeCaret(view, field, page)
        }
        return view
    }

    private func place(_ view: FieldTextView, _ field: OverlayField, _ page: Int) {
        guard let matrix = viewer.pageToView(page) else {
            view.outer.isHidden = true
            return
        }
        view.outer.isHidden = false
        let scale = ViewScale.of(matrix)
        let look = field.look
        let font = NSFont(name: CTFontCopyPostScriptName(OverlayPainter.font(look, look.size * scale)) as String, size: look.size * scale)
            ?? NSFont.systemFont(ofSize: look.size * scale)
        view.font = font
        view.textColor = color(look.color)
        view.backgroundColor = field.background.map(color) ?? NSColor.textBackgroundColor
        view.insertionPointColor = view.textColor ?? .labelColor
        view.alignment = alignment(look.alignment, rightToLeft: TextDirection.isRightToLeft(view.string))
        view.outer.layer?.borderColor = field.border.map { color($0).cgColor }
        view.outer.layer?.borderWidth = field.border == nil ? 0 : 1.5
        view.isHorizontallyResizable = !field.wraps
        view.autoresizingMask = field.wraps ? [.width] : []
        view.textContainer?.widthTracksTextView = field.wraps
        view.textContainer?.containerSize = NSSize(width: field.wraps ? field.area.width * scale : 1e7, height: 1e7)
        if view.string != field.text { view.string = field.text }

        var used: ViewSize?
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            let rect = layout.usedRect(for: container)
            used = ViewSize(rect.width + 4, rect.height)
        }
        let sheet = viewer.pageSize(page)
        let bounds = PageSpace.transform(matrix, ViewRect(0, 0, sheet.width, sheet.height))
        let frame = OverlayFieldFrame.of(field.area, matrix, used: used, wraps: field.wraps, bounds: bounds)
        let offset = viewer.offset
        view.outer.frame = NSRect(x: frame.x + offset.x, y: frame.y + offset.y, width: frame.width, height: frame.height)
        if let content = view.enclosingScrollView?.contentSize {
            view.minSize = content
            if field.wraps, view.frame.width != content.width { view.setFrameSize(NSSize(width: content.width, height: view.frame.height)) }
        }
    }

    private func placeCaret(_ view: FieldTextView, _ field: OverlayField, _ page: Int) {
        switch field.caret {
        case .all:
            view.selectAll(nil)
        case .end:
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        case .at(let point):
            guard let matrix = viewer.pageToView(page) else { return }
            let local = OverlayFieldFrame.local(point, in: field.area, scale: ViewScale.of(matrix))
            view.setSelectedRange(NSRange(location: view.characterIndexForInsertion(at: NSPoint(x: local.x, y: local.y)), length: 0))
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard let view = textView as? FieldTextView, let field = view.field, let text = replacementString else { return true }
        return field.accepts(view.string, replacing: range, with: text)
    }

    // A password shows as dots; the text view keeps the characters.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        var dot: UniChar = 0x2022
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(aFont, &dot, &glyph, 1) else { return 0 }
        let dots = [CGGlyph](repeating: glyph, count: glyphRange.length)
        dots.withUnsafeBufferPointer {
            layoutManager.setGlyphs($0.baseAddress!, properties: props, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? FieldTextView else { return }
        view.field?.typed(view.string)
        sync()
    }

    private func color(_ color: OverlayColor) -> NSColor {
        color.isAccent ? NSColor.controlAccentColor.withAlphaComponent(color.alpha)
            : NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    // A line that starts right to left begins at the right edge unless told otherwise, as the saved page does.
    private func alignment(_ align: TextAlign, rightToLeft: Bool) -> NSTextAlignment {
        switch align {
        case .leading: return rightToLeft ? .right : .left
        case .left: return .left
        case .center: return .center
        case .trailing: return .right
        case .justified: return .justified
        }
    }
}
#endif
#endif
