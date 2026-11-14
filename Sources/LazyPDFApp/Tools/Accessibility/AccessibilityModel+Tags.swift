import Foundation
import LazyPDFKit

// Follows AccessibilityPanel.Tree.cs and AccessibilityPanel.Tags.cs: the tag tree of the file, read from a copy off the main
// actor (the tags and figures views both show it), and tagging a file that has none.

extension AccessibilityModel {
    private struct TreeRead {
        let copy: PdfDocument
        let tree: StructureTree?
        let figures: [FigureRow]
        let count: Int
    }

    func loadTree() {
        guard let tab, let host else { return }
        treeTicket += 1
        let ticket = treeTicket
        treeStale = false
        dropTree()
        tagNodes = []
        figures = []
        tagsNote = L10n.t("Reading the tags")
        figuresNote = tagsNote
        let open = OpenCopy.of(tab, host)
        Task { [self] in
            let read: TreeRead?
            do {
                read = try await Task.detached { () throws -> TreeRead in
                    let copy = try open()
                    let tree = StructureTree.read(copy)
                    return TreeRead(copy: copy, tree: tree, figures: tree.map { FigureFinder.list($0) } ?? [], count: tree?.elements.count ?? 0)
                }.value
            } catch {
                read = nil
            }
            if ticket != treeTicket { return }
            if let read {
                (treeCopy, tree, allFigures, treeCount) = (read.copy, read.tree, read.figures, read.count)
            } else {
                treeFailed = true
            }
            keepDrafts(read?.figures ?? [])
            renderTags()
            renderFigures()
        }
    }

    // A draft stays only while its figure is in the new list on the same page with the same description.
    private func keepDrafts(_ fresh: [FigureRow]) {
        drafts = drafts.filter { key, _ in
            guard let old = checkedFigures.first(where: { $0.key == key }) else { return false }
            return fresh.contains { $0.key == key && $0.page == old.page && $0.alt == old.alt }
        }
        checkedFigures = fresh
        syncPending()
    }

    // The copy is let go, not closed: a picture being found may still be reading it.
    func dropTree() {
        (tree, treeCopy, allFigures, treeCount, treeFailed) = (nil, nil, [], 0, false)
    }

    func renderTags() {
        guard let tree, !tree.roots.isEmpty else {
            tagNodes = []
            tagsNote = treeFailed ? L10n.t("The tags could not be read.")
                : untagged ? L10n.t("The file has no tags. Add them so a screen reader can read it in order.")
                : L10n.t("The file says it is tagged but holds no tags. Lazy PDF cannot add them to it.")
            return
        }
        tagsNote = tree.isTruncated
            ? L10n.t("The tree is too large to show whole. Pick a tag to go to its page.")
            : L10n.t("{0} tags. Pick one to go to its page.", treeCount)
        tagNodes = TagNode.roots(tree)
    }

    /// A tag of the tree was picked: the viewer goes to its page.
    public func selectNode(_ node: TagNode) {
        guard let element = node.element else { return }
        let page = FigureFinder.pageOf(element)
        if page >= 0 { viewer?.goToPage(page) }
    }

    func addTags() async {
        guard let tab, let host else { return }
        await ChangeGate.runAsync(tab, host, L10n.t("Add tags")) { [self] in
            guard self.tab === tab else { return }
            let document = tab.document
            let signed = document.isSigned
            var result: AutoTagResult?
            isTagging = true
            defer { isTagging = false }
            try await host.runBusy(L10n.t("Adding tags")) { token in
                do {
                    // The tagger edits the document as it goes, so Cancel stops it, waits for it to be done and then takes
                    // back what it did.
                    let job = Task.detached { try AutoTagger.tag(document, AutoTagOptions(AccessibilityEdits.languageOf(document))) }
                    let watcher = Task {
                        while !Task.isCancelled {
                            if token.isCancelled { return job.cancel() }
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                    }
                    defer { watcher.cancel() }
                    let found = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                    if token.isCancelled { throw CancellationError() }
                    result = found
                } catch let error where error is PdfReadException || error is InvalidOperationException {
                    try? tab.session.discard()
                    Self.notTagged(host)
                } catch {
                    try? tab.session.discard()
                    throw error
                }
            }
            if let result { showTagResult(tab, host, result, signed) }
        }
    }

    private static func notTagged(_ host: ToolHost) {
        host.showProblem(Problem(L10n.t("Tags not added"), L10n.t("The pages could not be tagged. Save a copy of the file and try again.")))
    }

    private func showTagResult(_ tab: DocumentTab, _ host: ToolHost, _ result: AutoTagResult, _ signed: Bool) {
        if result.alreadyTagged {
            host.showNotice(L10n.t("Already tagged"), L10n.t("The file has tags, so none were added. Look at them in the tag tree."), nil)
            return
        }
        if result.pages == 0 {
            host.showProblem(Problem(L10n.t("Nothing to tag"),
                                     L10n.t("No page could be tagged. Scans need text recognition first. Pages that share content cannot be tagged.")))
            return
        }
        do {
            if try !tab.commit(L10n.t("Add tags")) { return }
        } catch is PdfReadException {
            try? tab.session.discard()
            Self.notTagged(host)
            return
        } catch {
            try? tab.session.discard()
            ChangeGate.guarded(host, L10n.t("Add tags")) { throw error }
            return
        }
        let counts = L10n.t("{0} pages tagged: {1} headings, {2} paragraphs, {3} lists, {4} tables, {5} figures.",
                            result.pages, result.headings, result.paragraphs, result.lists, result.tables, result.figures)
        let skipped = result.skippedPages > 0 ? " " + L10n.t("{0} pages were left as they were.", result.skippedPages) : ""
        let broken = signed ? " " + L10n.t("The signatures no longer hold.") : ""
        let describe = result.figuresWithoutAlt.isEmpty ? nil : NoticeAction(L10n.t("Describe figures"), { [weak self] in self?.setView(.figures) })
        host.showNotice(L10n.t("Tags added"), counts + skipped + broken, describe)
        host.setStatus(L10n.t("Tags added."))
    }
}
