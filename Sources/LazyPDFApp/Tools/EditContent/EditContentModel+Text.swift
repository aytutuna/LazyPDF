import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/EditContentPanel.Text.cs: text on the page, typing over a line, reflowing a
// paragraph, a new text box, and the look of both.

extension EditContentModel {
    func newLook() -> OverlayTextLook {
        OverlayTextLook(family: newStyle.family, size: newStyle.size, bold: newStyle.style.contains(.bold),
                        italic: newStyle.style.contains(.italic), color: EditorLook.color(newStyle.color),
                        alignment: EditorLook.alignment(newStyle.alignment))
    }

    // MARK: The editor on the page

    func textClicked(_ page: Int, _ id: Int, _ at: ViewPoint) {
        guard let edits, let text = edits.object(page, id) as? TextObject, !text.lines.isEmpty else { return }
        if !allowed({ [weak self] in self?.textClicked(page, id, at) }) { return }
        guard let line = text.lines.min(by: { Self.distance(lineRect(page, $0), at) < Self.distance(lineRect(page, $1), at) }) else { return }
        let look = EditorLook.of(text, line: try? edits.editor(page).look(of: line.range), installed: InstalledFonts.families)
        pending = .line
        pendingPage = page
        pendingId = id
        pendingLine = line
        openEditor(page, lineRect(page, line), line.text, look, wrap: false, caret: at)
    }

    /// Opens a line of the selected block for typing, as a click in its middle does.
    public func editLine(_ row: EditRow) {
        finishPending()
        guard let text = selectedText(), let surface, row.id < text.lines.count else { return }
        let r = lineRect(surface.page, text.lines[row.id])
        textClicked(surface.page, text.id, ViewPoint(r.x + r.width / 2, r.y + r.height / 2))
    }

    private func lineRect(_ page: Int, _ line: TextObjectLine) -> ViewRect {
        guard let viewer else { return .empty }
        let d = viewer.geometry(page).toDisplay(line.bounds)
        return ViewRect(d.x, d.y, d.width, d.height)
    }

    private static func distance(_ r: ViewRect, _ p: ViewPoint) -> Double {
        Swift.max(Swift.max(r.left - p.x, p.x - r.right), Swift.max(r.top - p.y, p.y - r.bottom))
    }

    private func openEditor(_ page: Int, _ area: ViewRect, _ text: String, _ look: OverlayTextLook, wrap: Bool, caret: ViewPoint? = nil) {
        opened = (page, area, look, wrap)
        editor?.open(page: page, area: area, text: text, look: look, wrap: wrap, caret: caret)
    }

    /// Opens the selected block as one paragraph to retype.
    public func reflowParagraph() {
        finishPending()
        guard let text = selectedText(), let surface, let viewer else { return }
        if !allowed({ [weak self] in self?.reflowParagraph() }) { return }
        let d = viewer.geometry(surface.page).toDisplay(text.bounds)
        pending = .paragraph
        pendingPage = surface.page
        pendingId = text.id
        pendingOriginal = text.text.replacingOccurrences(of: #"\s*[\r\n]+\s*"#, with: " ", options: .regularExpression)
        openEditor(pendingPage, ViewRect(d.x, d.y, d.width, d.height), pendingOriginal,
                   EditorLook.of(text, installed: InstalledFonts.families), wrap: true)
    }

    func areaDrawn(_ page: Int, _ area: PdfRect) {
        guard let surface, let viewer else { return }
        switch surface.mode {
        case .textBox:
            if !allowed({ [weak self] in self?.areaDrawn(page, area) }) { return }
            let d = viewer.geometry(page).toDisplay(area)
            pending = .newBox
            pendingPage = page
            pendingArea = area
            openEditor(page, ViewRect(d.x, d.y, d.width, d.height), "", newLook(), wrap: true)
        case .link:
            startLink(page, area, nil)
        case .crop:
            crop(page, area)
        case .select:
            break
        }
    }

    // Return, or the control losing the focus: the field has ended with this text. A new box that lost the focus waits for the
    // panel's size or font to be set first. If the engine refuses the text after a Return the box comes back with what was typed;
    // after a lost focus it stays closed, so that the panel can be used, and comes back with the next change of look. The reason
    // stays shown.
    func editorKept(_ text: String, focusLost: Bool) {
        if pending == .none { return }
        if focusLost && pending == .newBox {
            parked = text
            return
        }
        if commit(text) {
            cancelEditor()
        } else if focusLost {
            parked = text
        } else if let opened {
            editor?.open(page: opened.page, area: opened.area, text: text, look: opened.look, wrap: opened.wrap)
        }
    }

    private func reopenParked() {
        guard let text = parked, let opened else { return }
        parked = nil
        let look = pending == .newBox ? newLook() : opened.look
        openEditor(opened.page, opened.area, text, look, wrap: opened.wrap)
    }

    private func restyleBox() {
        guard pending == .newBox else { return }
        if parked != nil { reopenParked() } else { editor?.restyle(newLook()) }
    }

    // A press elsewhere on the page keeps what was typed; if the engine refuses it the editor goes, and the reason stays shown.
    func finishPending() {
        if pending != .none && !commitEditor() { cancelEditor() }
    }

    // True when the editor holds text that is not in the file yet.
    func hasTyped() -> Bool {
        guard let text = typedText() else { return false }
        switch pending {
        case .line: return text != pendingLine?.text
        case .paragraph: return text != pendingOriginal
        case .newBox: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .none: return false
        }
    }

    private func typedText() -> String? {
        if let editor, editor.isOpen { return editor.text }
        return parked
    }

    func cancelEditor() {
        editor?.close()
        pending = .none
        parked = nil
    }

    @discardableResult
    func commitEditor() -> Bool {
        guard pending != .none, let text = typedText() else { return true }
        if !commit(text) { return false }
        cancelEditor()
        return true
    }

    private func commit(_ text: String) -> Bool {
        guard let edits else { return true }
        let page = pendingPage, id = pendingId
        switch pending {
        case .none:
            return true
        case .line:
            guard let line = pendingLine else { return true }
            return text == line.text || apply({ try edits.replaceLine(page, line, text) }, L10n.t("Text changed."))
        case .paragraph:
            return text == pendingOriginal || apply({ try edits.replaceParagraph(page, id, text) }, L10n.t("Paragraph changed."))
        case .newBox:
            let box = pendingArea, style = newStyle
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || apply({ try edits.addTextBox(page, box, text, style) }, L10n.t("Text box added."))
        }
    }

    // MARK: Look

    func restyle(_ change: TextStyleChange, _ status: String) {
        guard let surface, let edits else { return }
        if surface.mode == .select {
            editSelectedText(status) { page, id in try edits.style(page, id, change) }
            return
        }
        var flags = newStyle.style
        if let bold = change.bold { if bold { flags.insert(.bold) } else { flags.remove(.bold) } }
        if let italic = change.italic { if italic { flags.insert(.italic) } else { flags.remove(.italic) } }
        newStyle.family = change.family ?? newStyle.family
        newStyle.size = change.size ?? newStyle.size
        newStyle.color = change.color ?? newStyle.color
        newStyle.style = flags
        restyleBox()
    }

    // What is typed in the box is kept first, so that the change is made to the page as it will be and not as it was.
    private func editSelectedText(_ status: String, _ edit: @escaping (Int, Int) throws -> EditOutcome) {
        if (pending == .line || pending == .paragraph) && !commitEditor() {
            reopenParked()
            return
        }
        guard let text = selectedText(), let surface else { return }
        let page = surface.page, id = text.id
        apply({ try edit(page, id) }, status)
    }

    private var currentFont: String {
        selectedText().map { EditorLook.nameOf($0.font, installed: InstalledFonts.families) } ?? newStyle.family
    }

    /// A family picked from the list.
    public func chooseFont(_ family: String) {
        fontName = family
        if family != currentFont { restyle(TextStyleChange(family: family), L10n.t("Font changed.")) }
    }

    /// A family typed in the box, once Return is pressed.
    public func commitFont() {
        let family = fontName.trimmingCharacters(in: .whitespaces)
        if family.isEmpty { return }
        restyle(TextStyleChange(family: family), L10n.t("Font changed."))
    }

    public func commitSize() {
        let now = selectedText()?.size ?? newStyle.size
        guard let size = Self.parse(sizeText, min: 1, max: 500) else {
            sizeText = Self.number(now)
            return
        }
        if abs(size - now) > 0.05 { restyle(TextStyleChange(size: size), L10n.t("Size changed.")) }
    }

    public func commitSpacing() {
        guard let text = selectedText(), let edits else { return }
        guard let spacing = Self.parse(spacingText, min: 1, max: 500) else {
            spacingText = Self.number(text.lineSpacing)
            return
        }
        if abs(spacing - text.lineSpacing) > 0.05 {
            editSelectedText(L10n.t("Spacing changed.")) { page, id in try edits.space(page, id, spacing) }
        }
    }

    public func setBold(_ on: Bool) {
        bold = on
        restyle(TextStyleChange(bold: on), L10n.t("Bold changed."))
    }

    public func setItalic(_ on: Bool) {
        italic = on
        restyle(TextStyleChange(italic: on), L10n.t("Italic changed."))
    }

    public func chooseTextColor(_ color: RgbColor) {
        restyle(TextStyleChange(color: color), L10n.t("Color changed."))
    }

    public func setAlignment(_ new: LazyPDFKit.TextAlignment) {
        guard let surface, let edits else { return }
        alignment = new
        if surface.mode == .select {
            editSelectedText(L10n.t("Aligned.")) { page, id in try edits.align(page, id, new) }
            return
        }
        newStyle.alignment = new
        restyleBox()
    }
}
