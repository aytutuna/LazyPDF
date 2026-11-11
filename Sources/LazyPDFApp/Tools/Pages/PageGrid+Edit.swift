import Foundation
import LazyPDFKit

// What the bar over the grid does (PagesPanel.Edit.cs and OrganizeView.Edit.cs): each call changes the file and commits it as
// one step, then makes the grid again with the pages that should be chosen.

extension PageGrid {
    @discardableResult
    func apply(_ label: String, select: [Int]?, status: String, _ change: (PdfDocument) throws -> Void) -> Bool {
        guard let tab, let host, PageJobs.apply(tab, host, label, change, status) else { return false }
        rebuild(select: select)
        onRebuild?()
        return true
    }

    @discardableResult
    func applyAsync(_ tab: DocumentTab, busy: String, label: String, select: [Int]?, status: String,
                    _ change: @escaping @Sendable (PdfDocument) throws -> Void) async -> Bool {
        guard let host, await PageJobs.applyAsync(tab, host, busy: busy, label: label, change, status: status) else { return false }
        // The person may have gone to another tab while it ran; its pages are then not on show to choose.
        if self.tab === tab {
            rebuild(select: select)
            onRebuild?()
        }
        return true
    }

    public func turn(_ pages: [Int], _ degrees: Int) {
        guard !pages.isEmpty else { return }
        apply(L10n.t("Rotate pages"), select: pages,
              status: L10n.plural(pages.count, one: "{0} page rotated", other: "{0} pages rotated")) { document in
            PageOperations.rotate(document, pages, degrees)
        }
    }

    public func remove(_ pages: [Int]) {
        guard !pages.isEmpty, !noneLeft(pages) else { return }
        let wasTagged = tab.map(PageJobs.isTagged) ?? false
        let done = apply(L10n.t("Delete pages"), select: nil,
                         status: L10n.plural(pages.count, one: "{0} page deleted", other: "{0} pages deleted")) { document in
            try PageOperations.delete(document, pages)
        }
        if done, let tab, let host { PageJobs.noteUntagged(tab, host, wasTagged: wasTagged) }
    }

    /// True, with the reason shown, when `pages` are every page there is.
    func noneLeft(_ pages: [Int]) -> Bool {
        if pages.count < cells.count { return false }
        host?.showProblem(Problem(L10n.t("Cannot delete every page"), L10n.t("A file needs at least one page. Leave one page out of the selection.")))
        return true
    }

    public func duplicate(_ pages: [Int]) async {
        guard let tab, !pages.isEmpty else { return }
        await applyAsync(tab, busy: L10n.t("Copying pages"), label: L10n.t("Duplicate pages"), select: PageEdits.duplicated(pages),
                         status: L10n.plural(pages.count, one: "{0} page duplicated", other: "{0} pages duplicated")) { document in
            try PageOperations.duplicate(document, pages)
        }
    }

    /// Moves the pages to stand before page `before`; true when they were moved.
    @discardableResult
    public func moveTo(_ pages: [Int], _ before: Int) -> Bool {
        guard !pages.isEmpty, before >= 0, before <= cells.count else { return false }
        return apply(L10n.t("Move pages"), select: PageEdits.movedTo(pages, before),
                     status: L10n.plural(pages.count, one: "{0} page moved", other: "{0} pages moved")) { document in
            try PageOperations.move(document, pages, before)
        }
    }

    public func earlier(_ pages: [Int]) { nudge(pages, -1) }

    public func later(_ pages: [Int]) { nudge(pages, 1) }

    public func canMove(_ step: Int) -> Bool {
        PageEdits.canNudge(selection, step, cells.count)
    }

    private func nudge(_ pages: [Int], _ step: Int) {
        guard PageEdits.canNudge(pages, step, cells.count) else { return }
        apply(L10n.t("Move pages"), select: PageEdits.nudged(pages, step, cells.count),
              status: L10n.plural(pages.count, one: "{0} page moved", other: "{0} pages moved")) { document in
            try PageEdits.nudge(document, pages, step)
        }
    }

    public func extract(_ pages: [Int]) async {
        guard let tab, let host, !pages.isEmpty else { return }
        let failed = Problem(L10n.t("Pages not extracted"), L10n.t("The pages could not be copied into a new file. Try fewer pages."))
        guard let bytes = await PageJobs.copyOut(tab, host, pages, busy: L10n.t("Extracting pages"), failed: failed) else { return }
        let stem = (tab.title as NSString).deletingPathExtension
        await host.openNew(bytes, title: L10n.t("{0} extract.pdf", stem), password: nil, certificate: nil)
        host.setStatus(L10n.plural(pages.count, one: "{0} page extracted", other: "{0} pages extracted"))
        CopyRules.noteUnprotected(tab.document, host)
    }

    public func blank(_ place: InsertPlace) {
        let at = PageEdits.insertAt(place, selection, cells.count)
        apply(L10n.t("Insert blank page"), select: [at], status: L10n.t("Blank page added.")) { document in
            let here = min(at, document.pages.count)
            let size = PageEdits.neighbourSize(document, here)
            try PageOperations.insertBlank(document, here, size.width, size.height)
        }
    }
}
