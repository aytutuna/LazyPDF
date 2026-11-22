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
    /// The page the scale fields show; set in `show` and nowhere else.
    public private(set) var shownPage = 0
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
    @ObservationIgnored private var state = MeasureState(PageScales(.actual), 0)
    @ObservationIgnored private var watch: ObservationWatch?
    @ObservationIgnored private var pageWatch: ObservationWatch?
    @ObservationIgnored private var toolWatch: ObservationWatch?
    @ObservationIgnored private var viewWatch: ObservationWatch?
    @ObservationIgnored private let fonts: FontSource

    // Kept per tab, so that measuring in one file and looking at another loses nothing.
    @ObservationIgnored private let states: TabTable<MeasureState>

    /// Set for a phone or tablet, where the hints speak of taps and the buttons, not of double clicks and Shift.
    @ObservationIgnored private let touch: Bool

    public init(fonts: FontSource, touch: Bool = false, state: TabToolState = TabToolState()) {
        self.fonts = fonts
        self.touch = touch
        states = state.measure
    }

    public var summary: String { ToolCatalog.find("measure")?.summary ?? "" }

    public var action: ToolAction? {
        ToolAction(L10n.t("Add to page"), symbol: "ruler", canRun: { [self] in !rows.isEmpty }, run: { [self] in add() })
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        states.prune()
        if let known = states[tab] {
            state = known
        } else {
            state = MeasureState(PageScales(MeasureScale.find(tab.document) ?? .actual), tab.rewrites)
            states[tab] = state
        }
        sync()
        scales.forgetFound()
        show(viewer.pageIndex)
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
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.documentChanged() })
        pageWatch = ObservationWatch(track: { _ = viewer.pageIndex }, changed: { [weak self] in
            guard let self, let tab = self.tab, let viewer = self.viewer, viewer.tab === tab, viewer.pageIndex != self.shownPage else { return }
            self.show(viewer.pageIndex)
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
        pageWatch?.stop()
        pageWatch = nil
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

    var scales: PageScales { state.scales }
    var waiting: PendingList { state.waiting }

    private var items: [MeasureItem] { waiting.items.map(\.item) }

    private func scaleOf(_ page: Int) -> MeasureScale {
        guard let tab else { return .actual }
        return scales.scale(tab.document, page)
    }

    // A save that numbered the objects again, made with another tool open, moved the pages under new numbers.
    private func sync() {
        guard let tab else { return }
        while state.seenRewrites < tab.rewrites {
            let map = tab.rewriteMaps[state.seenRewrites]
            state.seenRewrites += 1
            scales.remap(map)
            waiting.items = Pending.remap(waiting.items, map)
        }
    }

    private func documentChanged() {
        guard let tab else { return }
        sync()
        scales.forgetFound()
        scales.prune(tab.document)
        tool?.forget()
        dropStale()
        rebuild()
        show(shownPage)
    }

    // The viewer can be a step ahead of the model, on another tab or a page that is gone.
    private var shownPageIsLive: Bool {
        guard let tab, let viewer else { return false }
        return viewer.tab === tab && shownPage >= 0 && shownPage < tab.document.pages.count
    }

    /// The heading over the scale fields.
    public var scaleHeading: String {
        L10n.t("Scale for page {0}", viewer?.pageLabel(shownPage) ?? String(shownPage + 1))
    }

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
        let made = fieldScale()
        scaleProblem = made == nil
        guard let tab, let made, shownPageIsLive else { return }
        scales.set(PageScales.key(tab.document, shownPage), made)
        rebuild()
    }

    private func fieldScale() -> MeasureScale? {
        guard let page = Self.parse(pageValue), let real = Self.parse(realValue) else { return nil }
        let made = MeasureScale(page, pageUnit, real, realUnit)
        return made.isValid ? made : nil
    }

    /// Whether the scale in the fields can be applied to every page.
    public var canUseForAll: Bool { !scaleProblem && shownPageIsLive }

    /// Makes the scale in the fields the scale of every page, after asking when that replaces a scale another page has.
    public func useForAll() {
        guard let tab, shownPageIsLive, fieldScale() != nil else { return }
        let others = scales.otherScaleCount(except: PageScales.key(tab.document, shownPage), tab.document)
        if others == 0 {
            applyToAll()
            return
        }
        host?.showNotice(L10n.t("Replace the scales on the other pages?"),
                         L10n.plural(others, one: "The scale on {0} other page will be replaced.", other: "The scales on {0} other pages will be replaced."),
                         NoticeAction(L10n.t("Use for all pages")) { [weak self] in
                             if let self, self.tab === tab { self.applyToAll() }
                         })
    }

    private func applyToAll() {
        guard shownPageIsLive, let made = fieldScale() else { return }
        scales.setAll(made)
        show(shownPage)
        rebuild()
    }

    private func show(_ page: Int) {
        let shown = scaleOf(page)
        shownPage = page
        pageValue = Self.format(shown.page)
        realValue = Self.format(shown.real)
        pageUnit = shown.pageUnit
        realUnit = shown.realUnit
        scaleProblem = false
    }

    private static func format(_ value: Double) -> String {
        let format = NumberFormatter()
        format.numberStyle = .decimal
        format.locale = MeasureScale.locale
        format.usesGroupingSeparator = false
        format.maximumFractionDigits = 20
        // A calibrated scale is a long fraction; the field shows six digits, since a screen reader says them all.
        let shown = Double(String(format: "%.6g", value)) ?? value
        return format.string(from: NSNumber(value: shown)) ?? String(value)
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
        overlay?.draw(items) { [weak self] in self?.scaleOf($0) ?? .actual }
    }

    // Reads the list again after it or the scale changed.
    private func rebuild() {
        rows = waiting.items.map { pending in
            let item = pending.item
            return MeasureRow(id: pending.id, item: item, value: item.value(scaleOf(item.page)),
                              place: L10n.t("Page {0}", viewer?.pageLabel(item.page) ?? String(item.page + 1)),
                              removeName: L10n.t("Remove {0}", item.title))
        }
        tab?.pendingMeasurements = waiting.items.count
        redraw()
        showReadout()
    }

    // Marks that wait in the list go into the file before a save, an undo or a close, as Add to page does.
    // A file that cannot take marks, or is signed, keeps them waiting; the close question still names them.
    public func handIn() -> Bool {
        guard let tab, let host, !waiting.items.isEmpty, CommentExchange.canComment(tab.document),
              MarkWork.caution(tab.document) == nil else { return true }
        return write(tab, host)
    }

    // Moving to another tab or tool is no decision about the readings; they stay in the list of their tab.
    public func handInOnSwitch() -> Bool { true }

    private func add() {
        guard let tab, let host else { return }
        if !CommentExchange.canComment(tab.document) {
            host.showProblem(Problem(L10n.t("Not allowed"), L10n.t("This file does not let anyone add marks. Ask its owner for a copy that does.")))
            return
        }
        if !MarkWork.cautioned(tab, host, again: { [weak self] in
            if let self, self.tab === tab { _ = self.write(tab, host) }
        }) { _ = write(tab, host) }
    }

    private func write(_ tab: DocumentTab, _ host: ToolHost) -> Bool {
        let count: Int
        do {
            count = try MeasureWriter.write(tab.document, items, { [scales, document = tab.document] in scales.scale(document, $0.page) }, author: author, date: PanelDates.now(), fonts: fonts)
        } catch let error as PdfPermissionException {
            try? tab.session.discard()
            ChangeGate.guarded(host, L10n.t("Measure")) { throw error }
            return false
        } catch {
            try? tab.session.discard()
            host.showProblem(Problem(L10n.t("Measurements not added"), L10n.t("They could not be written to the file. Nothing was changed.")))
            rebuild()
            return false
        }
        // Whatever was written is one step, so Undo takes all of it back.
        do {
            if !(try MarkWork.commit(tab, host, L10n.t("Measure"))) { return false }
        } catch {
            try? tab.session.discard()
            ChangeGate.guarded(host, L10n.t("Measure")) { throw error }
            return false
        }
        waiting.items.removeAll()
        rebuild()
        host.setStatus(L10n.plural(count, one: "Added {0} measurement", other: "Added {0} measurements"))
        return true
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
        if touch && kind != nil { hint += " " + L10n.t("Two fingers scroll the page.") }
        guard let tool, !tool.points.isEmpty else {
            readout = "—"
            return
        }
        var points = tool.points
        if let hover = tool.hover, tool.hoverPage == tool.page { points.append(hover) }
        readout = points.count < 2 ? "—" : MeasureItem(tool.kind, tool.page, points).value(scaleOf(tool.page))
    }
}

/// The measurements of one tab that wait to be written.
final class PendingList {
    var items: [Pending] = []
}

/// What the model keeps for one tab: its scales, its waiting measurements and how many rewrites of the file it has seen.
final class MeasureState {
    let scales: PageScales
    let waiting = PendingList()
    var seenRewrites: Int

    init(_ scales: PageScales, _ seenRewrites: Int) {
        self.scales = scales
        self.seenRewrites = seenRewrites
    }
}
