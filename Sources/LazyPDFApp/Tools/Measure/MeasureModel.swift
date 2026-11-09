import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Measure/MeasurePanel.xaml.cs: distance, perimeter and area on the pages. The pointer
// draws on an overlay; the measurements wait in the list until Add to page writes them as annotations with a /Measure scale,
// in one undoable step.

/// A measurement in the list: what it is, its value and where it lies.
public struct MeasureRow: Identifiable, Equatable {
    public let id: UUID
    public let item: MeasureItem
    public let value: String
    public let place: String
    public let removeName: String

    public var spoken: String { "\(item.title), \(value), \(place)" }
}

@MainActor
@Observable
public final class MeasureModel: ToolPanelModel {
    public static let pageUnits: [LengthUnit] = [.millimetre, .centimetre, .inch]
    public static let realUnits = LengthUnit.allCases

    /// The kind being measured; nil while the viewer's own Hand or Select button holds the pointer.
    public private(set) var kind: MeasureKind? = .distance
    public private(set) var pageValue = "1"
    public private(set) var realValue = "1"
    public private(set) var pageUnit = LengthUnit.millimetre
    public private(set) var realUnit = LengthUnit.millimetre
    public private(set) var scaleProblem = false
    public private(set) var snapOn = true
    public private(set) var straight = false
    public private(set) var rows: [MeasureRow] = []
    public private(set) var hint = ""
    public private(set) var readout = "—"
    public private(set) var canFinish = false
    public private(set) var canStartOver = false

    /// The name put on the written marks; the system's user name until the view gives a better one.
    @ObservationIgnored public var author = NSFullUserName()

    var tab: DocumentTab?
    @ObservationIgnored var viewer: DocumentViewer?
    @ObservationIgnored var host: ToolHost?
    @ObservationIgnored var tool: MeasureTool?
    @ObservationIgnored private var overlay: MeasureOverlay?
    @ObservationIgnored private var scale = MeasureScale.actual
    @ObservationIgnored private var waiting = PendingList()
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var toolWatch: ObservationWatch?
    @ObservationIgnored private var viewWatch: ObservationWatch?
    @ObservationIgnored private let fonts: FontSource

    // Kept per tab, so that measuring in one file and looking at another loses nothing.
    @ObservationIgnored private var lists: [ObjectIdentifier: (tab: WeakTab, list: PendingList)] = [:]

    private struct WeakTab {
        weak var tab: DocumentTab?
    }

    /// Set for a phone or tablet, where the hints speak of taps and the buttons, not of double clicks and Shift.
    @ObservationIgnored private let touch: Bool

    public init(fonts: FontSource, touch: Bool = false) {
        self.fonts = fonts
        self.touch = touch
    }

    public var summary: String { ToolCatalog.find("measure")?.summary ?? "" }

    public var action: ToolAction? {
        ToolAction(L10n.t("Add to page"), symbol: "ruler", canRun: { [self] in !rows.isEmpty }, run: { [self] in add() })
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        lists = lists.filter { $0.value.tab.tab != nil }
        if let known = lists[ObjectIdentifier(tab)] {
            waiting = known.list
        } else {
            waiting = PendingList()
            lists[ObjectIdentifier(tab)] = (WeakTab(tab: tab), waiting)
        }
        if kind == nil { kind = .distance }
        let tool = MeasureTool(viewer: viewer)
        tool.kind = kind ?? .distance
        tool.snap = snapOn
        tool.straight = straight
        tool.changed = { [weak self] in self?.toolChanged() }
        tool.finished = { [weak self] item in self?.finished(item) }
        self.tool = tool
        overlay = MeasureOverlay(viewer: viewer, tool: tool)
        viewer.pointerTool = tool
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in
            self?.tool?.forget()
            self?.dropStale()
            self?.rebuild()
        })
        // The viewer's own Hand and Select buttons took the pointer: none of the kinds is armed until one is picked again.
        toolWatch = ObservationWatch(track: { _ = viewer.pointerTool }, changed: { [weak self] in
            guard let self, let tool = self.tool, let viewer = self.viewer, self.kind != nil else { return }
            if viewer.pointerTool.map({ ObjectIdentifier($0) }) != ObjectIdentifier(tool) {
                tool.reset()
                self.kind = nil
                self.showReadout()
            }
        })
        viewWatch = ObservationWatch(track: { _ = viewer.viewRevision }, changed: { [weak self] in
            guard let self, let tool = self.tool else { return }
            tool.preload(self.viewer?.visiblePages ?? [])
            self.redraw()
        })
        tool.preload(viewer.visiblePages)
        dropStale()
        rebuild()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        toolWatch?.stop()
        toolWatch = nil
        viewWatch?.stop()
        viewWatch = nil
        if let viewer, let tool, viewer.pointerTool.map({ ObjectIdentifier($0) }) == ObjectIdentifier(tool) { viewer.pointerTool = nil }
        tool?.changed = nil
        tool?.finished = nil
        overlay?.clear()
        tool = nil
        overlay = nil
        rows = []
        tab = nil
        viewer = nil
        host = nil
    }

    private var items: [MeasureItem] { waiting.items.map(\.item) }

    /// Picks Distance, Perimeter or Area, and arms the pointer for it.
    public func pick(_ next: MeasureKind) {
        guard let tool, let viewer else { return }
        kind = next
        tool.reset()
        tool.kind = next
        if viewer.pointerTool.map({ ObjectIdentifier($0) }) != ObjectIdentifier(tool) { viewer.pointerTool = tool }
        showReadout()
    }

    public func setSnap(_ on: Bool) {
        snapOn = on
        tool?.snap = on
    }

    public func setStraight(_ on: Bool) {
        straight = on
        tool?.straight = on
    }

    public func setPageValue(_ text: String) {
        pageValue = text
        scaleChanged()
    }

    public func setRealValue(_ text: String) {
        realValue = text
        scaleChanged()
    }

    public func setPageUnit(_ unit: LengthUnit) {
        pageUnit = unit
        scaleChanged()
    }

    public func setRealUnit(_ unit: LengthUnit) {
        realUnit = unit
        scaleChanged()
    }

    private func scaleChanged() {
        let page = Self.parse(pageValue), real = Self.parse(realValue)
        let made = MeasureScale(page ?? 0, pageUnit, real ?? 0, realUnit)
        let good = page != nil && real != nil && made.isValid
        scaleProblem = !good
        if !good { return }
        scale = made
        rebuild()
    }

    private static func parse(_ text: String) -> Double? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let format = NumberFormatter()
        format.numberStyle = .decimal
        format.locale = MeasureScale.locale
        return format.number(from: typed)?.doubleValue ?? Double(typed)
    }

    /// Ends the area or perimeter being drawn at the corner it has.
    public func finish() {
        tool?.finish()
    }

    public func startOver() {
        tool?.reset()
    }

    /// Takes back the last corner.
    public func takeBack() {
        tool?.undo()
    }

    public func remove(_ row: MeasureRow) {
        waiting.items.removeAll { $0.id == row.id }
        rebuild()
    }

    private func toolChanged() {
        redraw()
        showReadout()
    }

    private func finished(_ item: MeasureItem) {
        guard let tab, item.page < tab.document.pages.count else { return }
        waiting.items.append(Pending(item: item, key: PageKey.of(tab.document.pages[item.page])))
        rebuild()
    }

    // Measurements wait with display points of a page as it was; a page that was turned, cut or removed no longer takes them.
    private func dropStale() {
        guard let tab else { return }
        let kept = Pending.keep(waiting.items, tab.document)
        let dropped = waiting.items.count - kept.count
        waiting.items = kept
        if dropped > 0 { host?.showNotice(L10n.t("Measurements dropped"), L10n.t("The pages they were on changed. Measure them again."), nil) }
    }

    private func redraw() {
        overlay?.draw(items, scale)
    }

    // Reads the list again after it or the scale changed.
    private func rebuild() {
        rows = waiting.items.map { pending in
            let item = pending.item
            return MeasureRow(id: pending.id, item: item, value: item.value(scale),
                              place: L10n.t("Page {0}", viewer?.pageLabel(item.page) ?? String(item.page + 1)),
                              removeName: L10n.t("Remove {0}", item.title))
        }
        redraw()
        showReadout()
    }

    private func add() {
        guard let tab, let host else { return }
        if !CommentExchange.canComment(tab.document) {
            host.showProblem(Problem(L10n.t("Not allowed"), L10n.t("This file does not let anyone add marks. Ask its owner for a copy that does.")))
            return
        }
        if !MarkWork.cautioned(tab, host, again: { [weak self] in
            if let self, self.tab === tab { self.write(tab, host) }
        }) { write(tab, host) }
    }

    private func write(_ tab: DocumentTab, _ host: ToolHost) {
        var count = 0
        var failure: Error?
        do {
            count = try MeasureWriter.write(tab.document, items, scale, author: author, date: PanelDates.now(), fonts: fonts)
        } catch {
            failure = error
        }
        // Whatever was written is one step, so Undo takes all of it back.
        do {
            try tab.commit(L10n.t("Measure"))
        } catch {
            try? tab.session.discard()
            failure = failure ?? error
        }
        if let failure {
            ChangeGate.guarded(host, L10n.t("Measure")) { throw failure }
            return
        }
        waiting.items.removeAll()
        rebuild()
        host.setStatus(L10n.plural(count, one: "Added {0} measurement", other: "Added {0} measurements"))
    }

    private func showReadout() {
        canFinish = tool?.canFinish == true
        canStartOver = tool?.points.isEmpty == false
        switch kind {
        case nil: hint = L10n.t("Pick Distance, Perimeter or Area to measure again.")
        case .distance?: hint = touch ? L10n.t("Tap the two ends. Turn on Straight lines to keep them straight.")
            : L10n.t("Click the two ends. Hold Shift for straight lines.")
        default: hint = touch ? L10n.t("Tap each corner, then tap Finish. Turn on Straight lines to keep them straight.")
            : L10n.t("Click each corner, then double-click to finish. Hold Shift for straight lines.")
        }
        guard let tool, !tool.points.isEmpty else {
            readout = "—"
            return
        }
        var points = tool.points
        if let hover = tool.hover, tool.hoverPage == tool.page { points.append(hover) }
        readout = points.count < 2 ? "—" : MeasureItem(tool.kind, tool.page, points).value(scale)
    }
}

/// The measurements of one tab that wait to be written.
final class PendingList {
    var items: [Pending] = []
}
