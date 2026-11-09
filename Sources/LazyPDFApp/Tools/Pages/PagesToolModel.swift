import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Pages/PagesPanel.xaml.cs and PagesPanel.Edit.cs: the pages in a grid small enough for the
// inspector, to choose, drag into a new order and change from the bar above; below are the jobs that need a choice first
// (insert, crop, resize, page labels). The button on top opens the same grid on the stage (OrganizeModel). The sections are in
// PagesToolModel+Sections.swift.

@MainActor
@Observable
public final class PagesToolModel: ToolPanelModel {
    public enum Section {
        case none, insert, crop, resize, labels
    }

    public let grid = PageGrid(boxWidth: 92, boxHeight: 124)
    public let asker = SourceQuestion()

    /// Where the pages of Insert and Replace go.
    public var place = InsertPlace.afterSelection

    /// The pages to take from the other file, as typed ("1-3, 5"); empty takes all.
    public var taken = ""

    public internal(set) var section = Section.none
    public internal(set) var cropDrawing = false
    public internal(set) var cropBox: CropBox?
    public var cropAll = false
    public var paperIndex = 0
    public var customWidth = "210"
    public var customHeight = "297"
    public var scaleContent = true
    public var labelStyleIndex = 0
    public var labelPrefix = ""
    public var labelStart = "1"

    /// The grid on the stage while it is held there; nil otherwise.
    public private(set) var organize: OrganizeModel?

    @ObservationIgnored var tab: DocumentTab?
    @ObservationIgnored var host: ToolHost?
    @ObservationIgnored var viewer: DocumentViewer?
    @ObservationIgnored var crop: CropTool?
    @ObservationIgnored var modeWatch: ObservationWatch?

    public init() {}

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        asker.choices = { [weak host] in host?.certificateChoices() ?? [] }
        grid.onSelect = { [weak self] in self?.selectionChanged() }
        grid.onRebuild = { [weak self] in self?.pagesChanged() }
        grid.attach(tab, host)
        arm()
    }

    public func detach() {
        closeOrganize()
        disarm()
        asker.giveUp()
        grid.onSelect = nil
        grid.onRebuild = nil
        grid.detach()
        tab = nil
        viewer = nil
        host = nil
    }

    // One page chosen is the page shown.
    private func selectionChanged() {
        guard grid.selected.count == 1, let page = grid.selected.first, let viewer, viewer.pageIndex != page else { return }
        viewer.goToPage(page)
    }

    // A box drawn on a page that is gone cannot be used.
    private func pagesChanged() {
        if let box = crop?.box, box.page >= grid.cells.count { crop?.clear() }
    }

    public func openOrganize() {
        guard organize == nil, let tab, let viewer, let host else { return }
        let view = OrganizeModel()
        view.onClose = { [weak self] in self?.closeOrganize() }
        view.attach(tab, viewer, host)
        organize = view
        host.holdStage(true)
    }

    public func closeOrganize() {
        guard let view = organize else { return }
        organize = nil
        host?.holdStage(false)
        view.detach()
    }

    public var canEdit: Bool { !grid.selected.isEmpty }
    public var canMoveEarlier: Bool { (grid.selection.first ?? 0) > 0 }
    public var canMoveLater: Bool { canEdit && (grid.selection.last ?? 0) < grid.cells.count - 1 }

    public func turn(_ degrees: Int) {
        grid.turn(grid.selection, degrees)
    }

    public func remove() {
        grid.remove(grid.selection)
    }

    public func duplicate() async {
        await grid.duplicate(grid.selection)
    }

    public func extract() async {
        await grid.extract(grid.selection)
    }

    public func earlier() {
        grid.earlier(grid.selection)
    }

    public func later() {
        grid.later(grid.selection)
    }

    public func blank() {
        grid.blank(place)
    }

    private struct Picked {
        let source: PdfDocument
        let pages: [Int]
    }

    // A PDF chosen by the person, opened off the main actor, with the pages the box asks for. Nil when there is none to use.
    private func pickPages(_ host: ToolHost) async -> Picked? {
        guard let file = await host.filePicker.pickFiles([.pdf], multiple: false).first,
              let source = await SourceFile.open(host, file, asker) else { return nil }
        if taken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Picked(source: source, pages: Array(0..<source.pages.count))
        }
        let range = PageRange.parse(taken, source.pages.count)
        if let error = range.error {
            host.showProblem(Problem(L10n.t("Pages not understood"), error.message))
            return nil
        }
        return Picked(source: source, pages: range.pages)
    }

    public func fromFile() async {
        guard tab != nil, let host else { return }
        let at = PageEdits.insertAt(place, grid.selection, grid.cells.count)
        guard let picked = await pickPages(host) else { return }
        let source = picked.source, pages = picked.pages
        await grid.applyAsync(busy: L10n.t("Adding pages"), label: L10n.t("Insert pages"), select: Array(at..<at + pages.count),
                              status: L10n.plural(pages.count, one: "{0} page added", other: "{0} pages added")) { document in
            try PageOperations.importPages(document, source, pages, min(at, document.pages.count))
        }
    }

    public func replace() async {
        let chosen = grid.selection
        guard tab != nil, let host, let last = chosen.last else { return }
        guard let picked = await pickPages(host) else { return }
        let source = picked.source, pages = picked.pages
        let first = last + 1 - chosen.count
        await grid.applyAsync(busy: L10n.t("Replacing pages"), label: L10n.t("Replace pages"), select: Array(first..<first + pages.count),
                              status: L10n.t("Pages replaced.")) { document in
            try PageEdits.replace(document, chosen, source, pages)
        }
    }
}
