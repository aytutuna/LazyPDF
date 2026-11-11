import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FormsPanel.xaml.cs and its partial files. Filling a form on the page and editing its
// fields. Filling opens fields on the pages and lists every field in the panel; editing draws, moves, resizes and sets up the
// fields themselves. Every change goes through the tab as one undoable step.

@MainActor
@Observable
public final class FormsModel: ToolPanelModel {
    public private(set) var rows: [FieldRow] = []
    public private(set) var summary = ""
    public private(set) var note: String?
    public private(set) var designing = false

    /// The form can be filled in: it is not dynamic XFA and the file's permissions allow filling.
    public private(set) var canFillForm = false

    /// The fields themselves can change.
    public private(set) var canEdit = false
    public internal(set) var isWorking = false
    public private(set) var highlight = true

    /// The row of a list or drop-down the person tapped on the page; the panel shows its choices.
    public private(set) var activeRow: String?

    // The new field to draw, the selected field and the card that sets it up.
    public var newKind: FieldKind?
    public var groupName = ""
    public internal(set) var selected: String?
    public internal(set) var selectedIndex = 0
    public internal(set) var selectedOrdinal = 0
    public internal(set) var cardKind: FieldKind?
    public internal(set) var cardFlags = FieldFlags.none
    public var nameDraft = ""
    public var hintDraft = ""
    public var lengthDraft = ""
    public var choicesDraft = ""
    public var startDraft = ""
    public var captionDraft = ""
    public var exportDraft = ""
    public var sizeDraft = ""
    public var targetDraft = ""
    public internal(set) var fontName: String?
    public internal(set) var colourIndex: Int?
    public internal(set) var actionKind = ButtonActionKind.none
    public internal(set) var tabOrder = TabOrder.annotations

    // The fields the detector found.
    public internal(set) var found: [FoundRow] = []
    public internal(set) var foundText = ""
    public internal(set) var foundShown = false

    // Form data files.
    public var dataFormat = DataFormat.fdf

    /// The box of the card that has the keyboard, which the view reports; what is typed in it goes into the file when the panel
    /// is handed in, since a view that goes away does not report a lost focus.
    @ObservationIgnored public var cardFocus: CardProperty?

    var tab: DocumentTab?
    var host: ToolHost?
    var viewer: DocumentViewer?
    @ObservationIgnored let fonts: FontSource
    @ObservationIgnored var fill: FillLayer?
    @ObservationIgnored var frames: FieldFrames?
    @ObservationIgnored var designTool: FieldTool?
    @ObservationIgnored var fillTool: FillTool?
    @ObservationIgnored var cached: PdfForm?
    @ObservationIgnored var revision = 0
    @ObservationIgnored var loading = false
    @ObservationIgnored var signedOk = false
    @ObservationIgnored var signedPending = false
    @ObservationIgnored var loaded: PdfDocument?
    @ObservationIgnored private var fileWatch: ObservationWatch?
    @ObservationIgnored private var viewWatch: ObservationWatch?

    public init(fonts: FontSource) {
        self.fonts = fonts
    }

    public var action: ToolAction? {
        ToolAction(L10n.t("Flatten form"), symbol: "rectangle.compress.vertical",
                   hint: L10n.t("Makes the fields part of the page. They can no longer be filled in or changed."),
                   canRun: { [self] in canFlatten }, run: { [self] in await flatten() })
    }

    var form: PdfForm {
        if let cached { return cached }
        let read = FormEdits.read(tab!, fonts)
        cached = read
        return read
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.viewer = viewer
        self.host = host
        fill = FillLayer(viewer, enter: { [weak self] name, text in self?.enter(name, text) ?? false },
                         reset: { [weak self] names in self?.resetFields(names) },
                         sign: { [weak self] name in self?.host?.openSigning(name) },
                         pick: { [weak self] name, index in self?.activate(name, index) },
                         unsupported: { [weak self] text in self?.host?.showNotice(L10n.t("This button does nothing here"), text, nil) })
        fill?.highlight = highlight
        frames = FieldFrames(viewer)
        designTool = FieldTool(self)
        fillTool = FillTool(self)
        selected = nil
        found = []
        foundShown = false
        signedOk = false
        signedPending = false
        cardFocus = nil
        isWorking = false
        activeRow = nil
        defer { if !designing { syncTool() } }
        fileWatch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in
            if let self, let tab = self.tab, tab.revision != self.revision { self.reload() }
        })
        viewWatch = ObservationWatch(track: { _ = viewer.viewRevision; _ = viewer.visiblePages; _ = viewer.pageIndex; _ = viewer.pointerTool },
                                     changed: { [weak self] in self?.viewChanged() })
        reload()
    }

    public func detach() {
        fileWatch?.stop()
        viewWatch?.stop()
        fileWatch = nil
        viewWatch = nil
        fill?.clear()
        frames?.clear()
        if let viewer, viewer.pointerTool === designTool || viewer.pointerTool === fillTool { viewer.pointerTool = nil }
        rows = []
        fill = nil
        frames = nil
        designTool = nil
        fillTool = nil
        cached = nil
        tab = nil
        viewer = nil
        host = nil
    }

    // Waits while a signed file's question is on the info bar, since the text it asks about is held only by its button.
    public func handIn() -> Bool {
        if signedPending {
            if host?.isNoticeWaiting == true { return false }
            signedPending = false
        }
        commitCard()
        fill?.flush()
        return !signedPending
    }

    // The viewer hears of a changed file before the panel does; until the panel has read it again its form is the old one. An edit
    // running off the main actor owns the document, so nothing reads it meanwhile; the end of the edit looks again.
    func viewChanged() {
        guard let tab, let viewer, tab.revision == revision, !isWorking else { return }
        if designing {
            if viewer.pointerTool !== designTool && canEdit { setDesigning(false) } else { showTabOrder() }
        } else {
            // A declined press falls through to the viewer's own mode, so the fill tool stays under any pointer the person picks.
            if viewer.pointerTool == nil && canFillForm { viewer.pointerTool = fillTool }
            fill?.follow()
        }
        frames?.follow()
    }

    func endWork() {
        isWorking = false
        viewChanged()
    }

    func reload() {
        guard let tab else { return }
        cached = nil
        revision = tab.revision
        loaded = tab.document
        let form = self.form
        let open = form.xfa != .dynamic && form.canFill
        canFillForm = open
        canEdit = open && FormEdits.canModify(form.document)
        let made = fieldRows(of: form)
        if made != rows { rows = made }
        pruneFound(form)
        showSummary(form)
        if let activeRow, !rows.contains(where: { $0.id == activeRow }) { self.activeRow = nil }
        if designing { syncTool() }
        if designing {
            fill?.clear()
            showDesign(form)
        } else {
            frames?.clear()
            fill?.show(form, canFill: open)
        }
    }

    private func syncTool() {
        guard let viewer else { return }
        if designing && canEdit {
            viewer.pointerTool = designTool
        } else if !designing && canFillForm {
            viewer.pointerTool = fillTool
        } else if viewer.pointerTool === designTool || viewer.pointerTool === fillTool {
            viewer.pointerTool = nil
        }
    }

    public func setDesigning(_ on: Bool) {
        guard tab != nil, on != designing, handIn() else { return }
        designing = on
        selected = nil
        reload()
        if !on { syncTool() }
    }

    public func setHighlight(_ on: Bool) {
        highlight = on
        fill?.highlight = on
    }

    private func fieldRows(of form: PdfForm) -> [FieldRow] {
        var seen: [String: Int] = [:]
        return form.fields.map { field in
            let ordinal = seen[field.name, default: 0]
            seen[field.name] = ordinal + 1
            return row(field, ordinal)
        }
    }

    private func row(_ field: FormField, _ ordinal: Int) -> FieldRow {
        let page = field.widgets.first?.pageIndex ?? -1
        let kind = FormText.kindName(field.kind)
        let options = field.kind == .radio ? field.widgets.compactMap { ($0.export ?? $0.onState).map { FieldOption($0) } } : field.options
        return FieldRow(name: field.name, hint: field.tooltip ?? "", detail: page < 0 ? kind : L10n.t("{0}, page {1}", kind, page + 1),
                        page: page, index: 0, ordinal: ordinal, kind: field.kind, value: field.value ?? "",
                        isOn: field.kind == .checkBox && field.isChecked, selected: field.selected, options: options,
                        canFill: canFillForm && !field.has(.readOnly) && !(field.kind == .signature && field.isSigned),
                        isRequired: field.has(.required), isSecret: field.has(.password), multiSelect: field.has(.multiSelect),
                        isEditable: field.has(.edit))
    }

    private func showSummary(_ form: PdfForm) {
        let required = form.fields.filter { $0.has(.required) }.count
        if form.fields.isEmpty {
            summary = L10n.t("This file has no form fields.")
        } else if required == 0 {
            summary = L10n.plural(form.fields.count, one: "{0} field", other: "{0} fields")
        } else {
            summary = L10n.plural(form.fields.count, one: "{0} field, {1} required", other: "{0} fields, {1} required", required)
        }
        if form.xfa == .dynamic {
            note = FormText.dynamicXfa
        } else if !form.canFill {
            note = L10n.t("The permissions of this file do not allow filling in forms.")
        } else if designing && !canEdit {
            note = L10n.t("The permissions of this file do not allow changing its fields.")
        } else if form.xfa == .static {
            note = L10n.t("This form also has XFA data. Changing a field removes it.")
        } else if form.fields.isEmpty {
            note = L10n.t("Choose Edit fields to add some, or to find the blanks of a form.")
        } else {
            note = nil
        }
    }

    /// Goes to a field of the list and puts the keyboard in it (filling) or selects it (editing).
    public func focusRow(_ row: FieldRow) {
        guard !isWorking else { return }
        commitCard()
        guard let viewer, let widget = field(of: row)?.widgets.first, widget.pageIndex >= 0 else { return }
        let d = viewer.geometry(widget.pageIndex).toDisplay(widget.rect)
        viewer.goToPage(widget.pageIndex)
        viewer.reveal(widget.pageIndex, FieldFrames.box(d))
        if designing {
            select(row.name, row.index, row.ordinal)
        } else {
            fill?.focus(row.name, row.index)
            activeRow = row.kind == .comboBox || row.kind == .listBox ? row.id : nil
        }
    }

    func field(of row: FieldRow) -> FormField? {
        let same = form.findAll(row.name)
        return same.indices.contains(row.ordinal) ? same[row.ordinal] : nil
    }

    /// A tap on a button or a signature row.
    public func pressRow(_ row: FieldRow) {
        fill?.press(row.name, row.index)
    }

    public func toggleRow(_ row: FieldRow) {
        guard row.kind == .checkBox, row.canFill else { return }
        _ = enter(row.name, row.isOn ? "Off" : field(of: row)?.widgets.first?.onState ?? "Yes")
    }

    public func chooseRow(_ row: FieldRow, _ export: String) {
        guard row.canFill else { return }
        _ = enter(row.name, export)
    }

    public func chooseRow(_ row: FieldRow, many exports: [String]) {
        guard row.canFill else { return }
        _ = choose(row.name, exports)
    }

    /// One option of a list turned on or off. A list that takes one choice has the new one replace the old; turning the chosen one
    /// off is not an answer there, so it does nothing.
    public func setChoice(_ row: FieldRow, _ option: FieldOption, _ on: Bool) {
        guard row.canFill else { return }
        if !row.multiSelect {
            if on { _ = choose(row.name, [option.export]) }
            return
        }
        var picked = Set(row.chosen)
        if on { picked.insert(option.export) } else { picked.remove(option.export) }
        _ = choose(row.name, row.options.map(\.export).filter { picked.contains($0) })
    }

    public func typeRow(_ row: FieldRow, _ text: String) {
        guard row.canFill, text != row.value else { return }
        _ = enter(row.name, text)
    }

    // A list or drop-down tapped on the page.
    func activate(_ name: String, _ index: Int) {
        guard let row = rows.first(where: { $0.name == name }) else { return }
        activeRow = row.id
        host?.setStatus(L10n.t("Choose a value for {0} in the panel.", row.label))
    }

    var view: DocumentViewer { viewer! }

    func scale(_ page: Int) -> Double {
        viewer?.pageToView(page).map(ViewScale.of) ?? 1
    }

    /// 24 screen points in points of the page.
    func slop(_ page: Int) -> Double { 24 / max(scale(page), 0.01) }

    func fillHit(_ page: Int, _ point: ViewPoint) -> FillSlot? {
        isWorking ? nil : fill?.hit(page, point, slop: slop(page))
    }

    // A finger scrolls where it is not on a field; only a small mark is found a little off.
    func fillTakes(_ page: Int, _ point: ViewPoint) -> Bool {
        !isWorking && fill?.hit(page, point, slop: slop(page), exact: true) != nil
    }

    func fillActivate(_ slot: FillSlot, at point: ViewPoint) {
        fill?.activate(slot, at: point)
    }

    // What the person did in a field. The answer is whether the field kept it.
    @discardableResult
    func enter(_ name: String, _ text: String?) -> Bool {
        guard tab != nil, let host else { return false }
        if let text, let field = form.find(name), field.kind == .text || field.kind == .comboBox, let message = form.validate(field, text) {
            host.showProblem(Problem(L10n.t("Value not accepted"), message))
            return false
        }
        return fillIn { try $0.setValue(name, text) }
    }

    func choose(_ name: String, _ picked: [String]) -> Bool {
        tab != nil && fillIn { try $0.setChoices(name, picked) }
    }

    func resetFields(_ names: [String]?) {
        _ = edit(L10n.t("Reset form"), again: { [weak self] in self?.resetFields(names) }) { form -> Int in
            guard let names else { return try form.reset() }
            var count = 0
            for name in names { count += try form.reset(name) }
            return count
        }
    }

    private func fillIn(_ change: @escaping (PdfForm) throws -> FormFillResult) -> Bool {
        guard let host else { return false }
        let xfa = form.xfa == .static
        guard let result = edit(L10n.t("Fill form field"), again: { [weak self] in _ = self?.fillIn(change) }, change) else { return false }
        if !result.rejected.isEmpty {
            host.showProblem(Problem(L10n.t("Value not accepted"), L10n.t("This field does not take that value. Check it and try again.")))
            return false
        }
        if !result.notRun.isEmpty {
            host.showNotice(L10n.t("Script not run"), FormText.scriptNotRun, nil)
        } else if xfa {
            host.showNotice(L10n.t("XFA data removed"), FormText.xfaRemoved, nil)
        }
        return true
    }

    // One undoable step. Nothing happens while an edit runs, or before the person has agreed to change a signed file.
    func edit<T>(_ label: String, again: (@MainActor () -> Void)? = nil, _ change: (PdfForm) throws -> T) -> T? {
        guard let tab, !isWorking, !signed(again) else { return nil }
        return guarded { try FormEdits.apply(tab, fonts, label, change) }
    }

    // A change to a signed file leaves the signatures not covering what is now in it, and a certified file may forbid the change.
    func signed(_ again: (@MainActor () -> Void)? = nil) -> Bool {
        guard !signedOk, let tab, tab.document.isSigned, let host else { return false }
        signedPending = true
        host.showNotice(L10n.t("File is signed"), L10n.t("A change breaks its signatures or its certification. Change it only if that is fine."),
                        NoticeAction(L10n.t("Change anyway")) { [weak self] in
            guard let self else { return }
            self.signedOk = true
            self.signedPending = false
            if let again { again() } else { self.host?.setStatus(L10n.t("Now make the change again.")) }
        })
        return true
    }

    // The engine refuses what it cannot do with an error whose text says what to change.
    func guarded<T>(_ run: () throws -> T) -> T? {
        defer { afterEdit() }
        do {
            return try run()
        } catch is CancellationError {
            return nil
        } catch {
            host?.showProblem(problem(of: error))
            return nil
        }
    }

    func guardedAsync<T>(_ run: () async throws -> T) async throws -> T? {
        defer { afterEdit() }
        do {
            return try await run()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            host?.showProblem(problem(of: error))
            return nil
        }
    }

    private func problem(of error: Error) -> Problem {
        if error is PdfPermissionException { return Problems.restricted() }
        return FormEdits.problem(of: error)
    }

    // The panel reads the file again at once, since the tab's own change is only seen on the next turn.
    func afterEdit() {
        cached = nil
        if let tab, tab.revision != revision || tab.document !== loaded { reload() }
    }

    var canFlatten: Bool {
        guard let tab, !isWorking else { return false }
        let form = self.form
        return !form.fields.isEmpty && form.canFill && form.xfa != .dynamic && FormEdits.canModify(form.document)
    }

    func flatten() async {
        guard handIn() else { return }
        if signed({ [weak self] in Task { await self?.flatten() } }) { return }
        guard let host else { return }
        let burned = await runEdit(L10n.t("Flattening the form"), L10n.t("Flatten form")) { try $0.flatten() }
        if burned > 0 { host.setStatus(L10n.plural(burned, one: "{0} field flattened.", other: "{0} fields flattened.")) }
    }

    public func resetForm() async {
        guard handIn() else { return }
        if signed({ [weak self] in Task { await self?.resetForm() } }) { return }
        guard let host else { return }
        let done = await runEdit(L10n.t("Resetting the form"), L10n.t("Reset form")) { try $0.reset() }
        if done > 0 { host.setStatus(L10n.plural(done, one: "{0} field reset.", other: "{0} fields reset.")) }
    }

    // The edit runs off the main actor on the open document, so the panel and the fields over the page keep still meanwhile.
    private func runEdit(_ busy: String, _ label: String, _ change: @escaping @Sendable (PdfForm) throws -> Int) async -> Int {
        guard let tab, let host else { return 0 }
        var done = 0
        isWorking = true
        defer { endWork() }
        try? await host.runBusy(busy) { token in
            done = try await guardedAsync { try await FormEdits.applyAsync(tab, fonts, label, token: token, change) } ?? 0
        }
        return done
    }
}
