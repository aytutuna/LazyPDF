import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Comment/CommentPanel.xaml.cs: marks on the pages, text markup from a selection, shapes and
// notes drawn with the pointer, and the look they get. What the panel does to the file is in CommentModel+Marks.swift and
// the exchange of comment files, flattening and attaching in CommentModel+Exchange.swift.

/// A tool of the palette: what the person sees, and the sentence that says what to do on the page.
public struct MarkPaletteItem: Identifiable {
    public let tool: MarkTool
    public let text: String
    public let symbol: String
    public let hint: String

    public var id: MarkTool { tool }
}

/// The mark picked with the Move marks tool.
public struct SelectedMark: Equatable {
    public let title: String
    public let canEditText: Bool
}

@MainActor
@Observable
public final class CommentModel: ToolPanelModel {
    public static let families = ["Helvetica", "Times New Roman", "Courier New"]

    public private(set) var tool = MarkTool.selectText
    public private(set) var color: [Double]?
    public private(set) var width = 2.0
    public private(set) var opacity = 100.0
    public private(set) var family = "Helvetica"
    public private(set) var fontSize = 12.0
    public private(set) var bold = false
    public private(set) var italic = false
    public private(set) var stampName = AnnotationText.stampLabel(AnnotationText.standardStamps[0])
    public private(set) var allowed = true
    public private(set) var hint = ""
    public private(set) var selected: SelectedMark?
    public private(set) var flattenable = 0

    /// A polygon or cloud is under way and has corners enough to be finished.
    public private(set) var canFinishShape = false

    /// The name put on new marks; the system's user name until the view gives a better one.
    @ObservationIgnored public var author = NSFullUserName()

    var tab: DocumentTab?
    var viewer: DocumentViewer?
    var host: ToolHost?
    @ObservationIgnored let fonts: FontSource
    @ObservationIgnored var editTool: EditTool?
    @ObservationIgnored var drawTool: DrawTool?
    @ObservationIgnored var field: OverlayField?
    @ObservationIgnored private var active: PagePointerTool?
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var toolWatch: ObservationWatch?
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var unsettled = Set<LookPart>()
    @ObservationIgnored private var loading = false

    enum LookPart {
        case colour, width, opacity, font
    }

    public init(fonts: FontSource) {
        self.fonts = fonts
    }

    public var palette: [MarkPaletteItem] {
        [
            MarkPaletteItem(tool: .selectText, text: L10n.t("Select text"), symbol: "text.cursor", hint: L10n.t("Select text, then pick a markup above.")),
            MarkPaletteItem(tool: .edit, text: L10n.t("Move marks"), symbol: "cursorarrow", hint: L10n.t("Click a mark to move, resize or delete it.")),
            MarkPaletteItem(tool: .note, text: L10n.t("Note"), symbol: "note.text", hint: L10n.t("Click where the note goes.")),
            MarkPaletteItem(tool: .textBox, text: L10n.t("Text box"), symbol: "textbox", hint: L10n.t("Drag a box, then type.")),
            MarkPaletteItem(tool: .callout, text: L10n.t("Callout"), symbol: "bubble.left", hint: L10n.t("Drag from the spot to where the text goes.")),
            MarkPaletteItem(tool: .line, text: L10n.t("Line"), symbol: "line.diagonal", hint: L10n.t("Drag to draw a line.")),
            MarkPaletteItem(tool: .arrow, text: L10n.t("Arrow"), symbol: "arrow.up.right", hint: L10n.t("Drag to draw an arrow.")),
            MarkPaletteItem(tool: .rectangle, text: L10n.t("Rectangle"), symbol: "rectangle", hint: L10n.t("Drag to draw a rectangle.")),
            MarkPaletteItem(tool: .oval, text: L10n.t("Oval"), symbol: "circle", hint: L10n.t("Drag to draw an oval.")),
            MarkPaletteItem(tool: .polygon, text: L10n.t("Polygon"), symbol: "pentagon", hint: L10n.t("Click each corner, double-click to finish.")),
            MarkPaletteItem(tool: .cloud, text: L10n.t("Cloud"), symbol: "cloud", hint: L10n.t("Click each corner, double-click to finish.")),
            MarkPaletteItem(tool: .pencil, text: L10n.t("Pencil"), symbol: "pencil", hint: L10n.t("Drag to draw freehand.")),
            MarkPaletteItem(tool: .eraser, text: L10n.t("Eraser"), symbol: "eraser", hint: L10n.t("Drag over a drawing to erase it.")),
            MarkPaletteItem(tool: .stamp, text: L10n.t("Stamp"), symbol: "checkmark.seal", hint: L10n.t("Click where the stamp goes.")),
            MarkPaletteItem(tool: .attach, text: L10n.t("Attach file"), symbol: "paperclip", hint: L10n.t("Click where the file goes.")),
        ]
    }

    /// The colours of the swatches; the first, Automatic, takes the default of each kind of mark.
    public static var colours: [(name: String, rgb: [Double]?)] {
        [
            (L10n.t("Automatic"), nil), (L10n.t("Yellow"), [1, 0.92, 0.2]), (L10n.t("Orange"), [1, 0.6, 0.1]),
            (L10n.t("Red"), [0.9, 0.15, 0.15]), (L10n.t("Green"), [0.2, 0.7, 0.3]), (L10n.t("Blue"), [0.15, 0.4, 0.9]),
            (L10n.t("Purple"), [0.6, 0.3, 0.8]), (L10n.t("Black"), [0, 0, 0]),
        ]
    }

    /// The labels of the standard stamps, the choices of the stamp text.
    public var stamps: [String] { AnnotationText.standardStamps.map(AnnotationText.stampLabel) }

    /// Whether `rgb` is the colour the next mark takes, within the tolerance the swatches are matched by.
    public func isChosen(_ rgb: [Double]?) -> Bool {
        guard let chosen = color else { return rgb == nil }
        guard let rgb, rgb.count == chosen.count else { return false }
        return zip(rgb, chosen).allSatisfy { abs($0 - $1) < 0.03 }
    }

    /// The marks and the look can be changed: the file allows comments, and no long change is running.
    public var canChange: Bool { allowed && !MarkWork.shared.running }

    public var canExport: Bool { !MarkWork.shared.running }

    public var showsStamp: Bool { tool == .stamp }

    public var action: ToolAction? {
        ToolAction(L10n.t("Flatten comments"), symbol: "square.stack.3d.down.right",
                   canRun: { [self] in allowed && !MarkWork.shared.running && flattenable > 0 }, run: { [self] in await flatten() })
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        let edit = EditTool(viewer: viewer, marker: { [unowned self] in self.makeMarker(tab) })
        edit.selectionChanged = { [weak self] in self?.showSelected() }
        edit.moved = { [weak self] mark, dx, dy in _ = self?.change(L10n.t("Move")) { _ = try $0.move(mark, dx, dy) } }
        edit.resized = { [weak self] mark, box in _ = self?.change(L10n.t("Resize")) { _ = try $0.resize(mark, box) } }
        edit.editRequested = { [weak self] mark in self?.editText(of: mark) }
        edit.deleteRequested = { [weak self] in self?.deleteSelected() }
        editTool = edit
        allowed = Exchange.canComment(tab.document)
        if !allowed {
            tool = .selectText
        } else if let caution = MarkWork.caution(tab.document) {
            host.showNotice(L10n.t("File is signed"), caution, nil)
        }
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.editTool?.refresh()
            self.showSelected()
            self.countFlattenable(tab)
        })
        // The viewer's own Hand and Select buttons take the pointer back; the mode they chose stays.
        toolWatch = ObservationWatch(track: { _ = viewer.pointerTool }, changed: { [weak self] in
            guard let self, self.tool != .selectText, let viewer = self.viewer else { return }
            if !Self.same(viewer.pointerTool, self.active) {
                self.tool = .selectText
                self.choose(setMode: false)
            }
        })
        countFlattenable(tab)
        choose()
    }

    public func detach() {
        settling?.cancel()
        settling = nil
        unsettled = []
        field?.finish()
        watch?.stop()
        watch = nil
        toolWatch?.stop()
        toolWatch = nil
        if let viewer, active != nil, Self.same(viewer.pointerTool, active) { viewer.pointerTool = nil }
        editTool?.clear()
        editTool = nil
        drawTool = nil
        active = nil
        field = nil
        selected = nil
        canFinishShape = false
        tab = nil
        viewer = nil
        host = nil
    }

    public func handIn() -> Bool {
        field?.finish()
        return true
    }

    private static func same(_ a: PagePointerTool?, _ b: PagePointerTool?) -> Bool {
        a.map { ObjectIdentifier($0) } == b.map { ObjectIdentifier($0) }
    }

    func makeMarker(_ tab: DocumentTab) -> Marker {
        Marker(tab.document, fonts, author: author, date: PanelDates.now())
    }

    func currentStyle() -> MarkStyle {
        var font = FontStyles.regular
        if bold { font.insert(.bold) }
        if italic { font.insert(.italic) }
        return MarkStyle(color: color, width: width, opacity: opacity / 100, family: family, size: min(max(fontSize, 4), 144), font: font)
    }

    func countFlattenable(_ tab: DocumentTab) {
        flattenable = Exchange.flattenable(tab.document)
    }

    /// Picks the tool the pointer is, as a button of the palette does.
    public func pick(_ next: MarkTool) {
        guard tab != nil, allowed || next == .selectText else { return }
        tool = next
        choose()
    }

    /// Ends a polygon or cloud at the corner it has: the touch way of a double click.
    public func finishShape() {
        drawTool?.finishShape()
    }

    private func choose(setMode: Bool = true) {
        guard let viewer, let edit = editTool else { return }
        field?.finish()
        if tool != .edit { edit.clear() }
        drawTool = nil
        canFinishShape = false
        switch tool {
        case .selectText:
            active = nil
            if setMode { viewer.mode = .select }
        case .edit:
            active = edit
            viewer.pointerTool = edit
            edit.redraw()
        default:
            let draw = DrawTool(viewer: viewer, tool: tool, style: { [unowned self] in self.currentStyle() },
                                done: { [weak self] tool, page, points in self?.drew(tool, page, points) })
            draw.changed = { [weak self, weak draw] in self?.canFinishShape = draw?.canFinish ?? false }
            drawTool = draw
            active = draw
            viewer.pointerTool = draw
        }
        let item = palette.first { $0.tool == tool }
        let sentence = item?.hint ?? ""
        hint = !allowed ? L10n.t("This file does not allow comments.")
            : [.note, .textBox, .stamp, .attach].contains(tool) ? "\(sentence) \(L10n.t("Or press Enter on the page."))" : sentence
        showSelected()
    }

    public func setStampName(_ name: String) {
        stampName = name.isEmpty ? stamps[0] : name
    }

    public func setColor(_ rgb: [Double]?) {
        color = rgb
        lookChanged(.colour)
    }

    public func setWidth(_ value: Double) {
        width = min(max(value, 0.5), 12)
        lookChanged(.width)
    }

    public func setOpacity(_ value: Double) {
        opacity = min(max(value, 10), 100)
        lookChanged(.opacity)
    }

    public func setFamily(_ name: String) {
        family = name
        lookChanged(.font)
    }

    public func setFontSize(_ value: Double) {
        fontSize = min(max(value, 4), 144)
        lookChanged(.font)
    }

    public func setBold(_ on: Bool) {
        bold = on
        lookChanged(.font)
    }

    public func setItalic(_ on: Bool) {
        italic = on
        lookChanged(.font)
    }

    // The sliders settle for a moment before they change the selected mark, so a drag is one undo step.
    private func lookChanged(_ part: LookPart) {
        if loading || editTool?.current == nil { return }
        unsettled.insert(part)
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            self?.settle()
        }
    }

    /// Writes the look changes waiting for the slider to settle into the selected mark.
    func settle() {
        settling = nil
        let pending = unsettled
        unsettled = []
        guard let mark = editTool?.current, tab != nil else { return }
        let look = currentStyle()
        _ = change(L10n.t("Change look")) { m in
            var current = mark
            if pending.contains(.colour), let rgb = look.color { current = try m.recolor(current, rgb) }
            if pending.contains(.font), current.type == .freeText, Self.differs(Marker.textOf(current), look) { current = try m.restyle(current, look) }
            if pending.contains(.width) { current = try m.setWidth(current, look.width) }
            if pending.contains(.opacity) { _ = try m.setOpacity(current, look.opacity) }
        }
    }

    private static func differs(_ text: FreeTextStyle, _ look: MarkStyle) -> Bool {
        text.family != look.family || text.size != look.size || text.font != look.font
    }

    func showSelected() {
        guard let mark = editTool?.current else {
            selected = nil
            return
        }
        let text = mark.type == .freeText ? Marker.textOf(mark) : nil
        selected = SelectedMark(title: L10n.t("Selected: {0}", AnnotationText.kindName(mark.type)),
                                canEditText: mark.type == .text || mark.type == .freeText || !(mark.contents ?? "").isEmpty)
        loading = true
        width = min(max(mark.border.width, 0.5), 12)
        opacity = min(max((mark.opacity * 20).rounded(.toNearestOrEven) * 5, 10), 100)
        if let text {
            if Self.families.contains(text.family) { family = text.family }
            fontSize = (text.size * 10).rounded() / 10
            bold = text.font.contains(.bold)
            italic = text.font.contains(.italic)
        }
        // The swatch that matches the mark's colour is checked, and becomes the colour the next mark takes.
        color = Marker.rgb(of: text == nil ? mark.color : (text?.textColor ?? [0]))
        loading = false
    }
}
