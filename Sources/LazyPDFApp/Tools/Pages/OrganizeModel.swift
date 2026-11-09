import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Pages/OrganizeView.xaml.cs and OrganizeView.Edit.cs: the pages of the document tab as a large
// grid on the stage, held there by ToolHost.holdStage: choose, drag into a new order, rotate, delete, copy between tabs and drop
// files in. Each action is one commit.

@MainActor
@Observable
public final class OrganizeModel {
    public static let boxRatio = 1.4
    static let smallest = 72.0
    static let largest = 320.0

    public let grid = PageGrid(boxWidth: 140, boxHeight: 140 * boxRatio)
    public let asker: SourceQuestion
    public var place = InsertPlace.afterSelection

    /// The width of a page picture in the grid.
    public private(set) var tileSize = 140.0

    /// Called when the person is done and the stage should go back to the viewer.
    @ObservationIgnored public var onClose: (() -> Void)?

    @ObservationIgnored private var tab: DocumentTab?
    @ObservationIgnored private var host: ToolHost?
    @ObservationIgnored private var viewer: DocumentViewer?
    @ObservationIgnored private var sharpening: Task<Void, Never>?

    /// The panel passes its own `asker`, so a question from the stage shows in the sheet of the tool and not in a second one.
    public init(asker: SourceQuestion? = nil) {
        self.asker = asker ?? SourceQuestion()
    }

    public var canPaste: Bool { PageClipboard.shared.count > 0 }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        asker.choices = { [weak host] in host?.certificateChoices() ?? [] }
        grid.attach(tab, host)
    }

    public func detach() {
        sharpening?.cancel()
        sharpening = nil
        asker.giveUp()
        grid.detach()
        tab = nil
        viewer = nil
        host = nil
    }

    /// The pictures are made again at the new size once the slider stops, not at every step of it.
    public func setTileSize(_ size: Double) {
        tileSize = min(max(size, Self.smallest), Self.largest)
        grid.setBox(width: tileSize, height: tileSize * Self.boxRatio)
        sharpening?.cancel()
        sharpening = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !Task.isCancelled { self?.grid.sharpen() }
        }
    }

    public func done() {
        onClose?()
    }

    /// A double tap on a page shows it and goes back to the document.
    public func open(_ page: Int) {
        viewer?.goToPage(page)
        done()
    }

    public func turn(_ pages: [Int], _ degrees: Int) {
        grid.turn(pages, degrees)
    }

    public func turnSelection(_ degrees: Int) {
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

    public func copy() async {
        await copyPages(grid.selection)
    }

    public func cut() async {
        let pages = grid.selection
        guard !pages.isEmpty, !grid.noneLeft(pages), await copyPages(pages) else { return }
        grid.apply(L10n.t("Cut pages"), select: nil, status: L10n.plural(pages.count, one: "{0} page cut", other: "{0} pages cut")) { document in
            try PageOperations.delete(document, pages)
        }
    }

    /// True when the pages are on the clipboard.
    @discardableResult
    func copyPages(_ pages: [Int]) async -> Bool {
        guard let tab, let host, !pages.isEmpty else { return false }
        let failed = Problem(L10n.t("Pages not copied"), L10n.t("The pages could not be copied. Try fewer pages."))
        guard let bytes = await PageJobs.copyOut(tab, host, pages, busy: L10n.t("Copying pages"), failed: failed) else { return false }
        PageClipboard.shared.set(bytes, pages.count)
        host.setStatus(L10n.plural(pages.count, one: "{0} page copied", other: "{0} pages copied"))
        CopyRules.noteUnprotected(tab.document, host)
        return true
    }

    public func paste() async {
        guard let tab, let pdf = PageClipboard.shared.pdf, !pdf.isEmpty else { return }
        let at = insertIndex
        let count = PageClipboard.shared.count
        await grid.applyAsync(tab, busy: L10n.t("Adding pages"), label: L10n.t("Paste pages"), select: Array(at..<at + count),
                              status: L10n.plural(count, one: "{0} page pasted", other: "{0} pages pasted")) { document in
            let source = try PdfDocument.open(pdf)
            try Self.importAll(document, source, min(at, document.pages.count))
        }
    }

    var insertIndex: Int {
        PageEdits.insertAt(place, grid.selection, grid.cells.count)
    }

    nonisolated static func importAll(_ target: PdfDocument, _ source: PdfDocument, _ at: Int) throws {
        try PageOperations.importPages(target, source, Array(0..<source.pages.count), at)
    }

    public func blank() {
        grid.blank(place)
    }

    public func fromFile() async {
        guard let host else { return }
        let files = await host.filePicker.pickFiles([.pdf], multiple: true)
        if files.isEmpty { return }
        await insertFiles(files, at: insertIndex)
    }

    /// The files are opened one by one, then all their pages go in at `at` as one step.
    public func insertFiles(_ files: [ToolFile], at: Int) async {
        guard let host, let tab else { return }
        var pdfs: [ToolFile] = []
        for file in files {
            if file.url.pathExtension.lowercased() == "pdf" { pdfs.append(file) } else { file.access?.stop() }
        }
        if pdfs.isEmpty {
            host.showProblem(Problem(L10n.t("Not a PDF"), L10n.t("Only PDF files can be added between pages.")))
            return
        }
        var sources: [PdfDocument] = []
        for file in pdfs {
            if let source = await SourceFile.open(host, file, asker) { sources.append(source) }
        }
        let added = sources.reduce(0) { $0 + $1.pages.count }
        if added == 0 { return }
        let taken = sources
        await grid.applyAsync(tab, busy: L10n.t("Adding pages"), label: L10n.t("Insert pages"), select: Array(at..<at + added),
                              status: L10n.plural(added, one: "{0} page added", other: "{0} pages added")) { document in
            var place = min(at, document.pages.count)
            for source in taken {
                try Self.importAll(document, source, place)
                place += source.pages.count
            }
        }
    }
}
