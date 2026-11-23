import Foundation
import LazyPDFKit

// What the bar over the grid does (PagesPanel.Edit.cs and OrganizeView.Edit.cs): each call changes the file and commits it as
// one step, then makes the grid again with the pages that should be chosen.

extension PageGrid {
    /// The gated edit: a restricted file refuses it, a signed one asks first. `afterwards` runs once the change is committed,
    /// also when that happens from the notice's Go on anyway.
    @discardableResult
    func apply(_ label: String, select: [Int]?, status: String, afterwards: (@MainActor () -> Void)? = nil,
               _ change: @escaping (PdfDocument) throws -> Void) -> Bool {
        guard let tab, let host else { return false }
        return PageJobs.gated(tab, host) { [weak self] in
            self?.applyNow(tab, host, label, select: select, status: status, afterwards: afterwards, change) ?? false
        }
    }

    /// The edit without the gate, for a caller that gated a larger piece of work already.
    func applyNow(_ tab: DocumentTab, _ host: ToolHost, _ label: String, select: [Int]?, status: String,
                  afterwards: (@MainActor () -> Void)? = nil, _ change: (PdfDocument) throws -> Void) -> Bool {
        guard PageJobs.apply(tab, host, label, change, status) else { return false }
        rebuilt(tab, select: select)
        afterwards?()
        return true
    }

    @discardableResult
    func applyAsync(_ tab: DocumentTab, busy: String, label: String, select: [Int]?, status: String,
                    afterwards: (@MainActor () -> Void)? = nil, _ change: @escaping @Sendable (PdfDocument) throws -> Void) async -> Bool {
        guard let host else { return false }
        return await PageJobs.gatedAsync(tab, host) { [weak self] in
            await self?.applyAsyncNow(tab, host, busy: busy, label: label, select: select, status: status, afterwards: afterwards, change) ?? false
        }
    }

    func applyAsyncNow(_ tab: DocumentTab, _ host: ToolHost, busy: String, label: String, select: [Int]?, status: String,
                       afterwards: (@MainActor () -> Void)? = nil, _ change: @escaping @Sendable (PdfDocument) throws -> Void) async -> Bool {
        guard await PageJobs.applyAsync(tab, host, busy: busy, label: label, change, status: status) else { return false }
        rebuilt(tab, select: select)
        afterwards?()
        return true
    }

    /// Makes the cells again after `tab` was changed. The person may have gone to another tab while the change ran; its pages
    /// are then not on show to choose.
    func rebuilt(_ tab: DocumentTab, select: [Int]?) {
        guard self.tab === tab else { return }
        rebuild(select: select)
        onRebuild?()
    }

    public func turn(_ pages: [Int], _ degrees: Int) {
        guard !pages.isEmpty else { return }
        apply(L10n.t("Rotate pages"), select: pages,
              status: L10n.plural(pages.count, one: "{0} page rotated", other: "{0} pages rotated")) { document in
            PageOperations.rotate(document, pages, degrees)
        }
    }

    public func remove(_ pages: [Int]) {
        guard let tab, let host, !pages.isEmpty, !noneLeft(pages) else { return }
        let wasTagged = PageJobs.isTagged(tab)
        apply(L10n.t("Delete pages"), select: nil, status: L10n.plural(pages.count, one: "{0} page deleted", other: "{0} pages deleted"),
              afterwards: { PageJobs.noteUntagged(tab, host, wasTagged: wasTagged) }) { document in
            try PageOperations.delete(document, pages)
        }
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
        await PageTransfer.toNewTab(PageDragPayload(tab: tab, grid: self, pages: pages), host, files: true)
    }

    /// The other open files a menu can copy pages to.
    public var otherDocuments: [DocumentTab] {
        host?.openDocuments.filter { $0 !== tab && !$0.isDisposed } ?? []
    }

    /// What a menu and VoiceOver call `other`: its name, with its folder after it when another open file has the same name.
    public func copyLabel(_ other: DocumentTab) -> String {
        let clash = host?.openDocuments.contains { $0 !== other && !$0.isDisposed && $0.title == other.title } ?? false
        guard clash, let folder = other.url?.deletingLastPathComponent().lastPathComponent else { return other.title }
        return L10n.t("{0} ({1})", other.title, folder)
    }

    /// The "Copy to" entries of a menu and VoiceOver's actions: the pages go to the end of `other`.
    public func copy(_ pages: [Int], to other: DocumentTab) async {
        guard let tab, let host, !pages.isEmpty else { return }
        await PageTransfer.copy(PageDragPayload(tab: tab, grid: self, pages: pages), to: other, host: host)
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
