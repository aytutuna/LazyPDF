import Foundation
import LazyPDFKit

// Follows AccessibilityPanel.Tags.cs and AccessibilityPanel.TagEditor.cs: the lines of the tag tree, the fields of the picked
// element, the commands on a node, moving nodes and tagging what the page shows. Every change is one edit of the open
// document's own tree and one undo step (TagEdits.apply); the tree on the screen is a copy, read again after it.

extension AccessibilityModel {
    static let markPrefix = "tags.mark."

    var pickedRow: TagRow? { tagRows.first { $0.id == selectedTag } }
    var selectedKid: StructKid? { pickedRow?.kid }

    func resetTags() {
        tagRows = []
        hasTags = false
        tagReadOnly = nil
        tagMessage = ""
        selectedTag = nil
        selectedKey = nil
        openTags = []
        tagFiltered = nil
        tagFilter = ""
        showForm(nil)
    }

    // MARK: The lines

    // The lines of the nodes that are open. With a filter, only the elements it shows are listed.
    func rebuildRows(reselect: Bool = true) {
        guard let tree, !tree.roots.isEmpty else {
            tagRows = []
            return
        }
        var rows: [TagRow] = []
        func add(_ kid: StructKid, _ id: String, _ depth: Int) {
            var listed: [(Int, StructKid)] = []
            if let element = kid as? StructElement {
                for (at, child) in element.kids.enumerated() {
                    if let found = tagFiltered, let inner = child as? StructElement, !found.shows(inner) { continue }
                    if tagFiltered != nil && !(child is StructElement) { continue }
                    listed.append((at, child))
                }
            }
            let open = !listed.isEmpty && openTags.contains(TagPath.keyOf(kid))
            rows.append(TagRow(id: id, kid: kid, depth: depth, label: TagLabels.of(kid, tree), hasKids: !listed.isEmpty, isOpen: open))
            if !open { return }
            for (at, child) in listed.prefix(TagRow.shown) { add(child, id + "/\(at)", depth + 1) }
            if listed.count > TagRow.shown {
                rows.append(TagRow(id: id + "/more", kid: nil, depth: depth + 1, label: L10n.t("{0} more", listed.count - TagRow.shown),
                                   hasKids: false, isOpen: false))
            }
        }
        var shown = 0
        for (at, root) in tree.roots.enumerated() {
            if let found = tagFiltered, !found.shows(root) { continue }
            if shown == TagRow.shown { break }
            shown += 1
            add(root, "\(at)", 0)
        }
        tagRows = rows
        let match = selectedKey.flatMap { key in rows.first { $0.kid.map(TagPath.keyOf) == key } }
        if reselect {
            pick(match, goTo: false)
        } else if let match {
            selectedTag = match.id
        } else if selectedKey != nil {
            pick(nil, goTo: false)
        }
    }

    func filterChanged() {
        guard let tree else { return }
        tagFiltered = TagFilter.of(tree, tagFilter)
        if let found = tagFiltered {
            for element in tree.elements where found.shows(element) { openTags.insert(TagPath.keyOf(element)) }
        }
        showNote()
        rebuildRows(reselect: false)
    }

    /// Opens or closes a node.
    public func toggle(_ row: TagRow) {
        guard let kid = row.kid, row.hasKids else { return }
        let key = TagPath.keyOf(kid)
        if openTags.contains(key) { openTags.remove(key) } else { openTags.insert(key) }
        rebuildRows(reselect: false)
    }

    /// A line of the tree was picked: the viewer goes to its page, the page outlines it and the editor shows it.
    public func select(_ row: TagRow) {
        if row.isMore { return }
        pick(row, goTo: true)
    }

    private func pick(_ row: TagRow?, goTo: Bool) {
        selectedTag = row?.id
        selectedKey = row?.kid.map(TagPath.keyOf)
        tagMessage = ""
        showForm(row?.kid)
        if goTo, let kid = row?.kid {
            let page = Self.pageOf(kid)
            if page >= 0 { viewer?.goToPage(page) }
        }
        showMarks(row?.kid)
    }

    private static func pageOf(_ kid: StructKid) -> Int {
        switch kid {
        case let element as StructElement: return FigureFinder.pageOf(element)
        case let content as StructContent: return content.pageIndex
        case let object as StructObject: return object.pageIndex
        default: return -1
        }
    }

    private func say(_ text: String) {
        tagMessage = text
        host?.setStatus(text)
    }

    // MARK: The fields

    private static func isCell(_ tree: StructureTree, _ element: StructElement) -> Bool {
        ["TH", "TD"].contains(tree.standardType(element.type))
    }

    func showForm(_ kid: StructKid?) {
        guard let element = kid as? StructElement, let tree else {
            showsEditor = false
            editsCell = false
            loaded = nil
            formMessage = ""
            canApplyForm = false
            return
        }
        var next = TagForm()
        next.type = element.type
        next.title = element.title ?? ""
        next.alt = element.alt ?? ""
        next.actualText = element.actualText ?? ""
        next.lang = element.lang ?? ""
        let cell = Self.isCell(tree, element)
        if cell {
            let table = tree.tableAttributes(element)
            next.scope = table.scope?.rawValue ?? ""
            next.rowSpan = table.rowSpan.map { String($0) } ?? ""
            next.colSpan = table.colSpan.map { String($0) } ?? ""
            next.headers = table.headers.joined(separator: ", ")
        }
        loadingForm = true
        form = next
        loadingForm = false
        editsCell = cell
        showsEditor = true
        loaded = properties(of: element)
        validateForm()
    }

    private func properties(of element: StructElement) -> TagProperties {
        var table: TableAttributes?
        if let tree, Self.isCell(tree, element) {
            table = TagEdits.tableOf(scope: form.scope, rowSpan: form.rowSpan, colSpan: form.colSpan, headers: form.headers).attributes
        }
        return TagProperties(type: form.type, title: form.title, alt: form.alt, actualText: form.actualText, lang: form.lang, table: table)
    }

    // The rules answer while the field is typed in, so the reason stands next to the field before anything is written.
    func validateForm() {
        guard let element = selectedKid as? StructElement, let tree else { return }
        var message: String?
        let type = form.type.trimmingCharacters(in: .whitespacesAndNewlines)
        if type != element.type { message = TagEdits.typeRefusal(tree, element, type) }
        let lang = form.lang.trimmingCharacters(in: .whitespacesAndNewlines)
        if message == nil && !lang.isEmpty && !AccessibilityChecker.isLanguageTag(lang) {
            message = L10n.t("Write the language as a tag such as en-US or tr-TR.")
        }
        if message == nil && editsCell {
            message = TagEdits.tableOf(scope: form.scope, rowSpan: form.rowSpan, colSpan: form.colSpan, headers: form.headers).problem
        }
        formMessage = message ?? ""
        canApplyForm = tagReadOnly == nil && message == nil && loaded.map { $0 != properties(of: element) } == true
    }

    /// Writes the fields of the editor into the picked element.
    public func applyForm() {
        guard canApplyForm, let element = selectedKid as? StructElement else { return }
        let fields = properties(of: element)
        edit(L10n.t("Change tag"), element) { tree, kid in TagEdits.setProperties(tree, kid as! StructElement, fields) }
    }

    // MARK: The commands

    /// Whether the command means anything for the picked node; false greys its button.
    public func canRun(_ command: TagCommand) -> Bool {
        pickedRow.map { canRun(command, on: $0) } ?? false
    }

    public func canRun(_ command: TagCommand, on row: TagRow) -> Bool {
        guard tagReadOnly == nil, let kid = row.kid, let tree else { return false }
        return TagEdits.applies(tree, kid, command)
    }

    /// The command on a node of the tree, which is picked first.
    public func run(_ command: TagCommand, on row: TagRow) {
        if row.isMore { return }
        if row.id != selectedTag { pick(row, goTo: false) }
        run(command)
    }

    public func run(_ command: TagCommand) {
        guard let kid = selectedKid, let tree else { return }
        if let why = tagReadOnly {
            say(why)
            return
        }
        if !TagEdits.applies(tree, kid, command) {
            say(L10n.t("That cannot be done to this tag."))
            return
        }
        // The rule speaks before the edit, so a move that would break the nesting is never tried.
        if let reason = TagEdits.refusal(tree, kid, command) {
            say(reason)
            return
        }
        edit(TagEdits.label(command), kid) { t, k in try TagEdits.run(t, k!, command) }
    }

    // One edit, one undo step: the open document's own tree is read again, the node found there, the tree written and committed.
    func edit(_ label: String, _ kid: StructKid?, _ work: @escaping (StructureTree, StructKid?) throws -> String?) {
        guard let tab, let host, let shown = tree else { return }
        if let why = tagReadOnly {
            say(why)
            return
        }
        let path = kid.map { TagPath.of(shown, $0) }
        ChangeGate.run(tab, host, label) { [self] in
            guard self.tab === tab else { return }
            let outcome = TagEdits.apply(tab, path, label, work)
            switch outcome.result {
            case .done:
                tagMessage = ""
                host.setStatus(label + ".")
            case .unchanged:
                host.setStatus(L10n.t("Nothing to change."))
            case .refused:
                say(outcome.reason ?? "")
            case .gone:
                say(L10n.t("The tag is no longer in the file."))
            case .failed:
                host.showProblem(Problem(L10n.t("Tags not changed"), L10n.t("The tags of this file are too large to change here.")))
            }
        }
    }

    // MARK: Moving nodes

    /// A drop of the line `id` on `row`: before it, into it or after it. False when the structure would not allow it, with the reason in `tagMessage`.
    @discardableResult
    public func drop(_ id: String, onto row: TagRow, zone: DropZone) -> Bool {
        guard let dragged = tagRows.first(where: { $0.id == id }), let kid = dragged.kid, let target = row.kid, let tree else { return false }
        if let why = tagReadOnly {
            say(why)
            return false
        }
        do {
            if let reason = try TagEdits.drop(tree, kid, target, zone, apply: false) {
                say(reason)
                return false
            }
        } catch {
            return false
        }
        let to = TagPath.of(tree, target)
        if zone == .into { openTags.insert(TagPath.keyOf(target)) }
        edit(L10n.t("Move tag"), kid) { t, k in
            guard let found = to.find(t) else { return L10n.t("The tag is no longer in the file.") }
            return try TagEdits.drop(t, k!, found, zone, apply: true)
        }
        return true
    }

    /// A line was reordered by the list: it goes before the line now at `destination`, or last.
    public func moveRows(from source: IndexSet, to destination: Int) {
        guard let from = source.first, tagRows.indices.contains(from), destination != from, destination != from + 1 else { return }
        let before = destination < tagRows.count
        let target = tagRows[before ? destination : tagRows.count - 1]
        drop(tagRows[from].id, onto: target, zone: before ? .before : .after)
    }

    // MARK: Tagging what the page shows

    private func typeToTag() -> String? {
        let type = tagAs.trimmingCharacters(in: .whitespacesAndNewlines)
        if type.isEmpty { say(L10n.t("The type is empty.")) }
        return type.isEmpty ? nil : type
    }

    private func selectedRuns() async -> [SelectedRun]? {
        guard let viewer, viewer.hasSelection else {
            say(L10n.t("Select the text on the page first."))
            return nil
        }
        return await viewer.selection()
    }

    /// The page's text selection becomes a new tag of the chosen type under the picked element.
    public func tagSelection() async {
        guard let type = typeToTag(), let runs = await selectedRuns() else { return }
        edit(L10n.t("Tag selection"), selectedKid) { tree, kid in try TagEdits.tagSelection(tree, kid, type, runs) }
    }

    public func tagSelectionAsArtifact() async {
        guard let runs = await selectedRuns() else { return }
        edit(L10n.t("Mark as artifact"), nil) { tree, _ in try TagEdits.selectionAsArtifact(tree, runs) }
    }

    /// Takes a box drawn on the page as the content to tag.
    public func drawArea() {
        guard let viewer, typeToTag() != nil else { return }
        stopDraw()
        let tool = SignatureBoxTool(viewer, drawn: { [weak self] page, area in self?.areaDrawn(page, area) }, stopped: { [weak self] in self?.stopDraw() })
        drawTool = tool
        viewer.pointerTool = tool
        say(L10n.t("Drag on the page over what to tag."))
    }

    private func areaDrawn(_ page: Int, _ area: ViewRect) {
        let viewer = self.viewer
        stopDraw()
        guard let viewer, let type = typeToTag() else { return }
        tagArea(page, viewer.geometry(page).toUser(DisplayRect(area.x, area.y, area.width, area.height)), type)
    }

    func tagArea(_ page: Int, _ area: PdfRect, _ type: String) {
        edit(L10n.t("Tag area"), selectedKid) { tree, kid in try TagEdits.tagArea(tree, kid, type, page, area) }
    }

    func stopDraw() {
        guard let tool = drawTool else { return }
        drawTool = nil
        if viewer?.pointerTool === tool { viewer?.pointerTool = nil }
    }

    // MARK: Outlines on the page

    // The picked element's content, outlined on its pages; the outlines go when another node is picked or the tree is read again.
    func showMarks(_ kid: StructKid?) {
        boxTicket += 1
        clearMarks()
        guard view == .tags, let element = kid as? StructElement, let tree, viewer != nil else { return }
        let ticket = boxTicket
        let lock = treeLock
        Task { [self] in
            let found = await Task.detached { Self.boxes(tree, element, lock) }.value
            guard ticket == boxTicket, let viewer else { return }
            let style = OverlayStyle(stroke: .accent, fill: OverlayColor.accent.opacity(0.22), lineWidth: 1)
            for (at, box) in found.boxes.enumerated() {
                let area = viewer.geometry(box.pageIndex).toDisplay(box.rect)
                viewer.overlay(box.pageIndex).set(OverlayItem(Self.markPrefix + "\(at)", .rect(ViewRect(area.x, area.y, area.width, area.height)), style: style))
                markedPages.insert(box.pageIndex)
            }
        }
    }

    private nonisolated static func boxes(_ tree: StructureTree, _ element: StructElement, _ lock: NSLock) -> ElementBoxes {
        lock.lock()
        defer { lock.unlock() }
        return tree.boxes(element)
    }

    func clearMarks() {
        for page in markedPages { viewer?.overlay(page).remove(prefix: Self.markPrefix) }
        markedPages = []
    }
}
