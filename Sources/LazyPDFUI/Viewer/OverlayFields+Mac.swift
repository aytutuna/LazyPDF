#if canImport(SwiftUI)
#if os(macOS)
import AppKit
import CoreText
import LazyPDFApp
import LazyPDFKit

// The Mac side of OverlayField: a text view over the page for each open field, in the document view's coordinates. The text
// stays upright when the view is turned; it is scaled with the zoom. The field ends when the view loses the keyboard, on
// Return (Command-Return for a field of several lines) and on Escape.

final class FieldTextView: NSTextView {
    var field: OverlayField?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, let field, !field.multiline || event.modifierFlags.contains(.command) {
            field.commit(string)
        } else if event.keyCode == 53 {
            field?.drop()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { field?.commit(string) }
        return resigned
    }
}

@MainActor
final class OverlayFieldViews: NSObject, NSTextViewDelegate {
    private let viewer: ViewerModel
    private unowned let host: NSView
    private var shown: [ObjectIdentifier: FieldTextView] = [:]

    init(viewer: ViewerModel, host: NSView) {
        self.viewer = viewer
        self.host = host
    }

    // Makes, moves and removes the text views to match the open fields.
    func sync() {
        let open = viewer.openFields
        let live = Set(open.map { ObjectIdentifier($0.field) })
        for (key, view) in shown where !live.contains(key) {
            shown[key] = nil
            view.field = nil
            view.isHidden = true
            // The view may be the one that just gave up the keyboard; it leaves once that is over.
            DispatchQueue.main.async { view.removeFromSuperview() }
        }
        for (page, field) in open {
            let key = ObjectIdentifier(field)
            let view = shown[key] ?? make(field)
            place(view, field, page)
        }
    }

    private func make(_ field: OverlayField) -> FieldTextView {
        let view = FieldTextView(frame: .zero)
        view.field = field
        view.delegate = self
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 2
        view.wantsLayer = true
        view.string = field.text
        view.setAccessibilityLabel(field.label)
        shown[ObjectIdentifier(field)] = view
        host.addSubview(view)
        DispatchQueue.main.async { [weak view] in
            guard let view, view.field != nil else { return }
            view.window?.makeFirstResponder(view)
            view.selectAll(nil)
        }
        return view
    }

    private func place(_ view: FieldTextView, _ field: OverlayField, _ page: Int) {
        guard let matrix = viewer.pageToView(page) else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        let scale = (matrix.m11 * matrix.m11 + matrix.m12 * matrix.m12).squareRoot()
        let look = field.look
        let font = NSFont(name: CTFontCopyPostScriptName(OverlayPainter.font(look, look.size * scale)) as String, size: look.size * scale)
            ?? NSFont.systemFont(ofSize: look.size * scale)
        view.font = font
        view.textColor = color(look.color)
        view.backgroundColor = field.background.map(color) ?? NSColor.textBackgroundColor
        view.insertionPointColor = view.textColor ?? .labelColor
        view.alignment = alignment(look.alignment)
        view.layer?.borderColor = field.border.map { color($0).cgColor }
        view.layer?.borderWidth = field.border == nil ? 0 : 1.5
        view.isHorizontallyResizable = !field.wraps
        view.textContainer?.widthTracksTextView = field.wraps
        view.textContainer?.containerSize = NSSize(width: field.wraps ? field.area.width * scale : 1e7, height: 1e7)
        if view.string != field.text { view.string = field.text }

        let area = PageSpace.transform(matrix, field.area)
        let offset = viewer.offset
        var size = NSSize(width: area.width, height: area.height)
        if !field.wraps, let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            size = NSSize(width: Swift.max(size.width, used.width + 4), height: Swift.max(size.height, used.height))
        }
        view.frame = NSRect(x: area.x + offset.x, y: area.y + offset.y, width: size.width, height: size.height)
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? FieldTextView else { return }
        view.field?.typed(view.string)
        if let field = view.field, !field.wraps { sync() }
    }

    private func color(_ color: OverlayColor) -> NSColor {
        color.isAccent ? NSColor.controlAccentColor.withAlphaComponent(color.alpha)
            : NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private func alignment(_ align: TextAlign) -> NSTextAlignment {
        switch align {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        case .justified: return .justified
        }
    }
}
#endif
#endif
