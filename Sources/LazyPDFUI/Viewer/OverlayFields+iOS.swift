#if canImport(SwiftUI)
#if os(iOS)
import UIKit
import CoreText
import LazyPDFApp
import LazyPDFKit

// The iPhone and iPad side of OverlayField: a text view over the page for each open field, above the scroll view so a touch
// reaches it first, in the view's own coordinates. The text stays upright when the view is turned and is scaled with the
// zoom. With no Escape key on a phone, the keyboard carries a bar with Cancel and Done; the field also ends when it loses
// the keyboard, on Return (Command-Return for a field of several lines) and on Escape from a hardware keyboard; Tab goes to
// the field's own `onTab` when it has one. A field that takes the focus is scrolled into view above the keyboard.

final class FieldTextView: UITextView {
    var field: OverlayField?

    override var keyCommands: [UIKeyCommand]? {
        var commands = [UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commitFromKeys)),
                        UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dropFromKeys))]
        if field?.onTab != nil {
            for flags: UIKeyModifierFlags in [[], .shift] {
                let command = UIKeyCommand(input: "\t", modifierFlags: flags, action: #selector(tabbed(_:)))
                command.wantsPriorityOverSystemBehavior = true
                commands.append(command)
            }
        }
        return commands
    }

    @objc func tabbed(_ command: UIKeyCommand) {
        field?.onTab?(command.modifierFlags.contains(.shift))
    }

    @objc func commitFromKeys() {
        field?.commit(text)
    }

    @objc func dropFromKeys() {
        field?.drop()
    }
}

@MainActor
final class OverlayFieldViews: NSObject, UITextViewDelegate {
    private let viewer: ViewerModel
    private unowned let host: UIView
    private var shown: [ObjectIdentifier: FieldTextView] = [:]

    init(viewer: ViewerModel, host: UIView) {
        self.viewer = viewer
        self.host = host
    }

    /// The open text views, for the accessibility tree of the page view.
    var views: [UIView] { Array(shown.values) }

    /// Scrolls the field that has the keyboard into view, for when the keyboard has settled.
    func revealFocused() {
        for (page, field) in viewer.openFields {
            if let view = shown[ObjectIdentifier(field)], view.isFirstResponder { viewer.reveal(page, field.area) }
        }
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
            let view = shown[key] ?? make(field, page)
            place(view, field, page)
        }
    }

    private func make(_ field: OverlayField, _ page: Int) -> FieldTextView {
        let view = FieldTextView(frame: .zero)
        view.field = field
        view.delegate = self
        view.text = field.text
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 2
        view.layer.borderWidth = field.border == nil ? 0 : 1.5
        view.autocorrectionType = .default
        view.accessibilityLabel = field.label
        view.returnKeyType = field.multiline ? .default : .done
        view.isSecureTextEntry = field.secure
        view.inputAccessoryView = bar(for: view)
        shown[ObjectIdentifier(field)] = view
        host.addSubview(view)
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, let field = view.field else { return }
            view.becomeFirstResponder()
            self.placeCaret(view, field, page)
            self.revealFocused()
        }
        return view
    }

    private func bar(for view: FieldTextView) -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let cancel = UIBarButtonItem(title: L10n.t("Cancel"), primaryAction: UIAction { [weak view] _ in view?.field?.drop() })
        let done = UIBarButtonItem(title: L10n.t("Done"), primaryAction: UIAction { [weak view] _ in
            if let view { view.field?.commit(view.text) }
        })
        bar.items = [cancel, UIBarButtonItem.flexibleSpace(), done]
        return bar
    }

    private func place(_ view: FieldTextView, _ field: OverlayField, _ page: Int) {
        guard let matrix = viewer.pageToView(page) else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        let scale = ViewScale.of(matrix)
        let look = field.look
        let size = look.size * scale
        view.font = UIFont(name: CTFontCopyPostScriptName(OverlayPainter.font(look, size)) as String, size: size) ?? UIFont.systemFont(ofSize: size)
        view.textColor = color(look.color)
        view.backgroundColor = field.background.map(color) ?? UIColor.systemBackground
        view.tintColor = view.textColor
        view.textAlignment = alignment(look.alignment)
        view.layer.borderColor = (field.border.map(color) ?? .clear).cgColor
        view.textContainer.widthTracksTextView = field.wraps
        view.textContainer.size = CGSize(width: field.wraps ? field.area.width * scale : 1e7, height: 1e7)
        if view.text != field.text { view.text = field.text }

        view.layoutManager.ensureLayout(for: view.textContainer)
        let used = view.layoutManager.usedRect(for: view.textContainer)
        let frame = OverlayFieldFrame.of(field.area, matrix, used: ViewSize(used.width + 4, used.height), wraps: field.wraps)
        view.frame = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    private func placeCaret(_ view: FieldTextView, _ field: OverlayField, _ page: Int) {
        switch field.caret {
        case .all:
            view.selectAll(nil)
        case .end:
            view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        case .at(let point):
            guard let matrix = viewer.pageToView(page) else { return }
            let at = matrix.transform(point)
            let local = CGPoint(x: at.x - view.frame.minX, y: at.y - view.frame.minY)
            if let position = view.closestPosition(to: local) {
                let index = view.offset(from: view.beginningOfDocument, to: position)
                view.selectedRange = NSRange(location: index, length: 0)
            }
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let view = textView as? FieldTextView else { return }
        view.field?.typed(view.text)
        sync()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        guard let view = textView as? FieldTextView else { return }
        view.field?.commit(view.text, focusLost: true)
    }

    // Return ends a field of one line.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let view = textView as? FieldTextView, let field = view.field else { return true }
        if text == "\n", !field.multiline {
            field.commit(view.text)
            return false
        }
        return field.accepts(view.text, replacing: range, with: text)
    }

    private func color(_ color: OverlayColor) -> UIColor {
        color.isAccent ? UIColor.tintColor.withAlphaComponent(color.alpha)
            : UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
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
