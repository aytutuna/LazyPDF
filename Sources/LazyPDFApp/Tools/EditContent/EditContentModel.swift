import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/EditContentPanel.xaml.cs and its partial files: changes what is on the pages.
// Click a line of text and type over it, restyle or reflow a paragraph, move, resize, turn, delete and reorder pictures and
// shapes, add text boxes, pictures and links, and replace words in the whole file. The pointer work is in EditSurface, the
// typing in InPlaceEditor, the calls to the engine in ContentEdits; this model joins them to the panel's state. The text is in
// EditContentModel+Text.swift, the objects in +Objects, the links in +Links and replace all in +Find.

/// A sentence the panel shows under the hint, for what an edit came to.
public struct EditMessage: Equatable {
    public let text: String
    public let caution: Bool
}

/// Which parts of the panel the selection and the mode call for.
public struct EditSections: Equatable {
    public var addPicture = false
    public var text = false
    public var spacing = false
    public var paragraph = false
    public var paragraphEnabled = false
    public var image = false
    public var shape = false
    public var opacity = false
    public var arrange = false
    public var order = false
    public var link = false
    public var removeLink = false
}

/// A row of the lists that stand for what the pages show only as marks, so that it can be reached without the pointer.
public struct EditRow: Identifiable, Equatable {
    public let id: Int
    public let title: String
}

@MainActor
@Observable
public final class EditContentModel: ToolPanelModel {
    public private(set) var mode = EditMode.select

    /// The surface has the pointer; the viewer's Hand and Select buttons take it away.
    public private(set) var isActive = true
    public private(set) var hint = ""
    public private(set) var message: EditMessage?
    public private(set) var sections = EditSections()
    public private(set) var objectRows: [EditRow] = []
    public private(set) var linkRows: [EditRow] = []
    public private(set) var hasSelection = false

    public var fontName = ""
    public var sizeText = ""
    public var spacingText = ""
    public var widthText = ""
    public internal(set) var bold = false
    public internal(set) var italic = false
    public internal(set) var alignment = LazyPDFKit.TextAlignment.left
    public internal(set) var opacity = 100.0

    public var linkToPage = false
    public var linkText = ""

    /// Moves when the link box should take the keyboard.
    public internal(set) var linkFocus = 0

    public var findText = ""
    public var replaceText = ""
    public var matchCase = false
    public var wholeWord = false
    public internal(set) var isReplacing = false

    enum Pending {
        case none, line, paragraph, newBox
    }

    var pending = Pending.none
    var linkArea: PdfRect?

    @ObservationIgnored var tab: DocumentTab?
    @ObservationIgnored var host: ToolHost?
    @ObservationIgnored var viewer: DocumentViewer?
    @ObservationIgnored var edits: ContentEdits?
    @ObservationIgnored var surface: EditSurface?
    @ObservationIgnored var editor: InPlaceEditor?
    @ObservationIgnored var watch: ObservationWatch?
    @ObservationIgnored var pointerWatch: ObservationWatch?
    @ObservationIgnored var viewWatch: ObservationWatch?

    // The revision the panel's own last edit left the file at, so that a change from anywhere else is told apart from it.
    @ObservationIgnored var ownRevision = 0

    // The person said to go on with a signed file; asked once for as long as the panel is attached.
    @ObservationIgnored var signedOk = false

    @ObservationIgnored var pendingPage = 0
    @ObservationIgnored var pendingId = 0
    @ObservationIgnored var pendingLine: TextObjectLine?
    @ObservationIgnored var pendingOriginal = ""
    @ObservationIgnored var pendingArea = PdfRect(0, 0, 0, 0)

    // The text of a box that lost the keyboard to the panel, or that the engine refused: kept, with the box closed, until the
    // person restyles it (which opens it again), presses the page or uses the pinned button.
    var parked: String?
    @ObservationIgnored var opened: (page: Int, area: ViewRect, look: OverlayTextLook, wrap: Bool)?
    @ObservationIgnored var newStyle = TextBoxStyle(family: "Helvetica")
    @ObservationIgnored var linkPage = 0
    @ObservationIgnored var linkOld: PdfLink?
    @ObservationIgnored var opacityTask: Task<Void, Never>?
    @ObservationIgnored var opacityWanted: (page: Int, ids: [Int], value: Double)?
    @ObservationIgnored var rowsPage = -1

    public init() {}

    public var action: ToolAction? {
        switch pending {
        case .line, .paragraph, .newBox:
            return ToolAction(L10n.t("Apply text"), symbol: "checkmark", canRun: { [self] in editor?.isOpen == true || parked != nil },
                              run: { [self] in commitEditor() })
        case .none:
            guard mode == .link, linkArea != nil else { return nil }
            let text = linkOld == nil ? L10n.t("Add link") : L10n.t("Save link")
            return ToolAction(text, symbol: "link", canRun: { [self] in linkTarget() != nil }, run: { [self] in applyLink() })
        }
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        self.viewer = viewer
        signedOk = false
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        let edits = ContentEdits(tab, fonts: host.fontSource, codec: host.imageCodec, certificate: certificate)
        let surface = EditSurface(viewer, edits)
        let editor = InPlaceEditor(viewer)
        self.edits = edits
        self.surface = surface
        self.editor = editor
        surface.onPressing = { [weak self] in self?.finishPending() }
        surface.onSelectionChanged = { [weak self] in self?.selectionChanged() }
        surface.onTextClicked = { [weak self] page, id, at in self?.textClicked(page, id, at) }
        surface.onAreaDrawn = { [weak self] page, area in self?.areaDrawn(page, area) }
        surface.onLinkPicked = { [weak self] page, link in self?.startLink(page, link.rect, link) }
        surface.onMoveRequested = { [weak self] page, ids, dx, dy in
            self?.apply({ try edits.move(page, ids, dx, dy) }, L10n.t("Moved."))
        }
        surface.onResizeRequested = { [weak self] page, ids, bounds in
            self?.apply({ try edits.resize(page, ids, bounds) }, L10n.t("Resized."))
        }
        surface.onKey = { [weak self] key in self?.keyed(key) ?? false }
        editor.onKept = { [weak self] text, focusLost in self?.editorKept(text, focusLost: focusLost) }
        editor.onDropped = { [weak self] in self?.cancelEditor() }
        ownRevision = tab.revision
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.tabChanged() })
        pointerWatch = ObservationWatch(track: { _ = viewer.pointerTool; _ = viewer.mode }, changed: { [weak self] in self?.pointerChanged() })
        viewWatch = ObservationWatch(track: { _ = viewer.viewRevision; _ = viewer.pageIndex }, changed: { [weak self] in self?.viewChanged() })
        surface.attach()
        mode = .select
        hideMessage()
        refreshPanel()
    }

    // The window hands text in before it lets the tool go, but a field that the page view ends first has been heard already.
    public func detach() {
        _ = handIn()
        flushOpacity()
        editor?.close()
        pending = .none
        parked = nil
        linkArea = nil
        linkOld = nil
        surface?.detach()
        watch?.stop()
        pointerWatch?.stop()
        viewWatch?.stop()
        watch = nil
        pointerWatch = nil
        viewWatch = nil
        edits = nil
        surface = nil
        editor = nil
        viewer = nil
        tab = nil
        host = nil
    }

    public func handIn() -> Bool {
        flushOpacity()
        commitSize()
        commitSpacing()
        commitWidth()
        if pending != .none && !commitEditor(), let host, let message {
            host.showProblem(Problem(L10n.t("Typed text was not kept"), message.text))
        }
        return true
    }

    // MARK: Mode

    /// Picks what the pointer does. Picking the one already chosen gives the pointer back to the panel after the viewer's
    /// Hand or Select button took it.
    public func selectMode(_ new: EditMode) {
        guard let surface else { return }
        if new != surface.mode { modeChecked(new) }
        if !surface.isActive { surface.attach() }
        refreshPanel()
    }

    private func modeChecked(_ new: EditMode) {
        guard let surface else { return }
        hideMessage()
        finishPending()
        surface.clear()
        surface.setMode(new)
        linkArea = nil
        linkOld = nil
        surface.activeLink = nil
        refreshPanel()
    }

    // The Hand or Select button of the viewer took the pointer; it comes back when a mode here is picked.
    private func pointerChanged() {
        guard let surface, !surface.isActive else { return }
        finishPending()
        surface.detach()
        refreshPanel()
    }

    private func viewChanged() {
        if surface?.mode == .link { surface?.redrawAll() }
        if let viewer, viewer.pageIndex != rowsPage { refreshRows() }
    }

    private func tabChanged() {
        guard let tab, let surface, let editor else { return }
        if tab.revision == ownRevision { return }
        ownRevision = tab.revision
        if hasTyped(), let host {
            host.showProblem(Problem(L10n.t("Typed text was not kept"), L10n.t("The file changed while you typed. Type it again.")))
        }
        editor.close()
        pending = .none
        parked = nil
        endLink()
        surface.clear()
        surface.refresh()
        refreshPanel()
    }

    // Delete removes the selection and Escape lets go of it or of the mode, as long as no text is being typed.
    private func keyed(_ key: ViewerKey) -> Bool {
        guard let surface, editor?.isOpen != true else { return false }
        switch key {
        case .delete, .backspace:
            guard !surface.selected.isEmpty, surface.mode == .select else { return false }
            deleteSelection()
            return true
        case .escape:
            guard !surface.selected.isEmpty || surface.mode != .select else { return false }
            if surface.mode == .crop {
                surface.setMode(.select)
            } else if !surface.selected.isEmpty {
                surface.clear()
            } else {
                modeChecked(.select)
            }
            refreshPanel()
            return true
        default:
            return false
        }
    }

    // Clearing the selection keeps what is shown: a click on the page often ends an edit, and its note or reason is for that.
    private func selectionChanged() {
        flushOpacity()
        if let surface, !surface.selected.isEmpty { hideMessage() }
        refreshPanel()
    }

    // MARK: Edits

    /// Runs one edit of the document, shows what came of it and draws the selection again.
    @discardableResult
    func apply(_ change: @escaping () throws -> EditOutcome, _ status: String) -> Bool {
        guard let surface, let tab, let host else { return false }
        if !allowed({ [weak self] in self?.apply(change, status) }) { return false }
        let shape = shapeOf(surface)
        let outcome: EditOutcome
        do {
            outcome = try change()
        } catch is PdfPermissionException {
            ownRevision = tab.revision
            host.showProblem(Problems.restricted())
            return false
        } catch {
            outcome = EditOutcome(done: false, problem: L10n.t("The page changed. Select the object again."))
        }
        ownRevision = tab.revision
        if outcome.done {
            host.setStatus(status)

            // Object numbers are places in a list that is read again; if its shape changed they may name other objects.
            if shape == nil || shapeOf(surface) == shape { surface.refresh() } else { surface.clear() }
        }
        showOutcome(outcome)
        refreshPanel()
        return outcome.done
    }

    private func shapeOf(_ surface: EditSurface) -> [PageObjectKind]? {
        surface.page >= 0 ? edits?.objects(surface.page).map(\.kind) : nil
    }

    // False when the edit has to wait: the file forbids it, or the info bar asks first and goes on with it on a yes.
    func allowed(_ go: @escaping @MainActor () -> Void) -> Bool {
        guard let tab, let host else { return false }
        let document = tab.document
        if let problem = ChangeGate.refusal(document) {
            host.showProblem(problem)
            return false
        }
        if !document.isSigned || signedOk { return true }
        host.showNotice(L10n.t("Check before going on"), L10n.t("This file is signed, so changing it breaks the signatures."),
                        NoticeAction(L10n.t("Go on anyway")) { [weak self] in
                            self?.signedOk = true
                            go()
                        })
        return false
    }

    func showOutcome(_ outcome: EditOutcome) {
        if let problem = outcome.problem {
            message = EditMessage(text: problem, caution: true)
        } else if let note = outcome.note {
            message = EditMessage(text: note, caution: false)
        } else {
            message = nil
        }
    }

    func showMessage(_ text: String, caution: Bool) {
        message = EditMessage(text: text, caution: caution)
    }

    func hideMessage() {
        message = nil
    }

    // MARK: What the panel shows

    func selectedObjects() -> [PageObject] {
        guard let surface, let edits, surface.page >= 0 else { return [] }
        return edits.objects(surface.page, surface.selected)
    }

    func selectedText() -> TextObject? {
        let objects = selectedObjects()
        return objects.count == 1 ? objects[0] as? TextObject : nil
    }

    func refreshPanel() {
        guard let surface else { return }
        let objects = selectedObjects()
        let mode = surface.mode
        let text = objects.count == 1 ? objects[0] as? TextObject : nil
        let image = objects.count == 1 ? objects[0] as? ImageObject : nil
        let path = objects.count == 1 ? objects[0] as? PathObject : nil
        let inSelect = mode == .select
        self.mode = mode
        isActive = surface.isActive
        hasSelection = !objects.isEmpty
        if !isActive {
            hint = L10n.t("Pick a mode above to edit the page again.")
        } else {
            switch mode {
            case .textBox: hint = L10n.t("Drag a box on the page, then type.")
            case .link: hint = L10n.t("Drag an area to make a link, or click a link to change it.")
            case .crop: hint = L10n.t("Drag the part of the picture to keep.")
            case .select:
                hint = objects.isEmpty ? L10n.t("Click text or a picture to change it. Drag to select several.")
                    : L10n.t("Drag to move. Drag a handle to resize.")
            }
        }
        var shown = EditSections()
        shown.addPicture = inSelect
        shown.text = text != nil || mode == .textBox
        shown.image = image != nil && inSelect
        shown.shape = !objects.isEmpty && objects.allSatisfy { $0 is PathObject } && inSelect
        shown.opacity = !objects.isEmpty && inSelect && objects.allSatisfy { !($0 is TextObject) }
        shown.arrange = !objects.isEmpty && inSelect
        shown.order = image != nil || path != nil
        shown.link = mode == .link && linkArea != nil
        shown.removeLink = linkOld != nil
        if shown.text { fillText(text, &shown) }
        sections = shown
        if let image {
            opacity = (image.opacity * 100).rounded()
        } else if let path {
            opacity = (path.opacity * 100).rounded()
        }
        if let path { widthText = Self.number(path.lineWidth) }
        refreshRows()
    }

    private func fillText(_ text: TextObject?, _ shown: inout EditSections) {
        fontName = text.map { EditorLook.nameOf($0.font, installed: InstalledFonts.families) } ?? newStyle.family
        sizeText = Self.number(text?.size ?? newStyle.size)
        bold = text.map { $0.font?.isBold ?? false } ?? newStyle.style.contains(.bold)
        italic = text.map { $0.font?.isItalic ?? false } ?? newStyle.style.contains(.italic)
        alignment = text?.alignment ?? newStyle.alignment
        shown.spacing = (text?.lines.count ?? 0) > 1
        if let text { spacingText = Self.number(text.lineSpacing) }
        shown.paragraph = text != nil
        shown.paragraphEnabled = text.map { !$0.isTable } ?? false
    }

    /// The families a font can be picked from.
    public var fontChoices: [String] { InstalledFonts.families }

    /// The paragraph button's reason when it is off.
    public var paragraphReason: String? {
        selectedText()?.isTable == true ? L10n.t("A table is changed one line at a time.") : nil
    }

    // The objects of the page in view and its links, as lists, for what the page shows only as outlines.
    func refreshRows() {
        guard let viewer, let edits, viewer.pageCount > 0 else {
            objectRows = []
            linkRows = []
            return
        }
        let page = min(max(viewer.pageIndex, 0), viewer.pageCount - 1)
        rowsPage = viewer.pageIndex
        var pictures = 0, shapes = 0
        objectRows = edits.objects(page).prefix(200).map { object in
            switch object {
            case let text as TextObject:
                return EditRow(id: object.id, title: L10n.t("Text: {0}", Self.snippet(text.text)))
            case is ImageObject:
                pictures += 1
                return EditRow(id: object.id, title: L10n.t("Picture {0}", pictures))
            default:
                shapes += 1
                return EditRow(id: object.id, title: L10n.t("Shape {0}", shapes))
            }
        }
        guard mode == .link else {
            linkRows = []
            return
        }
        linkRows = edits.links(page).enumerated().map { EditRow(id: $0.offset, title: Self.describe($0.element)) }
    }

    /// Selects an object from the list.
    public func selectObject(_ row: EditRow) {
        guard let surface, let viewer, let edits else { return }
        let page = min(max(viewer.pageIndex, 0), viewer.pageCount - 1)
        finishPending()
        surface.select(page, [row.id])
        if let object = edits.object(page, row.id) { viewer.reveal(page, surface.pageRect(page, object.bounds)) }
    }

    static func snippet(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        return flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
    }

    static func describe(_ link: PdfLink) -> String {
        if let uri = link.uri { return L10n.t("Link to {0}", uri) }
        if let destination = link.destination, destination.pageIndex >= 0 { return L10n.t("Link to page {0}", destination.pageIndex + 1) }
        return L10n.t("Link")
    }

    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static func parse(_ text: String, min: Double, max: Double) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed) ?? NumberFormatter().number(from: trimmed)?.doubleValue else { return nil }
        return value >= min && value <= max ? value : nil
    }
}
