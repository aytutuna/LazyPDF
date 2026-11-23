import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Comment/CommentPanel.Marks.cs: what the panel does to the file, adding marks, changing the
// selected one, and the commit that makes each an undo step.

extension CommentModel {
    static let eraserReach = 4.0
    static let fieldId = "comment.text"

    /// Runs `work` on the file and commits it. False when the file refused the change and the person was told; a change the
    /// panel does not take at the moment counts as done.
    @discardableResult
    func change(_ label: String, _ work: (Marker) throws -> Void) -> Bool {
        guard let tab, let host, allowed, !MarkWork.shared.running else { return true }
        do {
            try work(makeMarker(tab))
        } catch let error as InvalidOperationException where error.message == AnnotationText.noFont {
            restore(tab)
            host.showProblem(Problem(L10n.t("Text not drawn"), AnnotationText.noFont))
            return false
        } catch MarkError.badPoint {
            restore(tab)
            return false
        } catch is ArgumentException {
            restore(tab)
            host.showProblem(Problem(L10n.t("Nothing to draw"), L10n.t("That mark has no area. Drag farther and try again.")))
            return false
        } catch {
            restore(tab)
            ChangeGate.guarded(host, label) { throw error }
            return false
        }
        do {
            if try MarkWork.commit(tab, host, label) { return true }
        } catch {
            restore(tab)
            ChangeGate.guarded(host, label) { throw error }
        }
        editTool?.refresh()
        return false
    }

    // Puts the file back as it was after a change failed halfway.
    private func restore(_ tab: DocumentTab) {
        try? tab.session.discard()
        editTool?.refresh()
    }

    func drew(_ tool: MarkTool, _ page: Int, _ points: [ViewPoint]) {
        // Undo can take the page away while a polygon is waiting for Finish.
        guard allowed, !MarkWork.shared.running, let tab, page >= 0, page < tab.document.pages.count else { return }
        let look = currentStyle()
        let label = tool == .eraser ? L10n.t("Erase") : (palette.first { $0.tool == tool }?.text ?? "")
        switch tool {
        case .eraser:
            change(label) { m in
                for mark in m.along(page, points, Self.eraserReach).filter(Marker.erasable) { m.delete(mark) }
            }
        case .note, .textBox, .callout:
            type(tool, page, points, look, label)
        case .stamp:
            change(label) { _ = try $0.addStamp(page, points[0], stampValue(), look) }
        case .attach:
            Task { await attachFile(page, points[0]) }
        default:
            change(label) { _ = try $0.add(tool, page, points, look) }
        }
    }

    private func stampValue() -> String {
        let typed = stampName.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return AnnotationText.standardStamps[0] }
        return AnnotationText.standardStamps.first { AnnotationText.stampLabel($0).caseInsensitiveCompare(typed) == .orderedSame } ?? typed
    }

    private func type(_ tool: MarkTool, _ page: Int, _ points: [ViewPoint], _ look: MarkStyle, _ label: String) {
        guard let tab else { return }
        let area = tool == .note ? ViewRect(points[0].x, points[0].y + Marker.noteSize, 170, 60) : Marker.box(for: tool, points)
        compose(tab, page, area, tool == .note ? 12 : look.size, "") { [self] text in
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || change(label) { _ = try $0.add(tool, page, points, look, text) }
        }
    }

    // The box opens again with the text when the file would not take it, so that nothing typed is lost.
    private func compose(_ tab: DocumentTab, _ page: Int, _ area: ViewRect, _ size: Double, _ text: String,
                         keep: @escaping (String) -> Bool) {
        guard let viewer else { return }
        let box = ViewRect(area.x, area.y, max(area.width, 120), max(area.height, 40))
        let opened = OverlayField(Self.fieldId, area: box, text: text, look: OverlayTextLook(size: size), multiline: true,
                                  label: L10n.t("Text of the mark")) { [weak self] typed in
            guard let self else { return }
            self.field = nil
            guard let typed, self.tab === tab, !keep(typed) else { return }
            Task { @MainActor [weak self] in
                if let self, self.tab === tab { self.compose(tab, page, area, size, typed, keep: keep) }
            }
        }
        field = viewer.overlay(page).open(opened)
    }

    /// Marks the selected text; `kind` is Highlight, Underline, StrikeOut or Squiggly.
    public func markup(_ kind: AnnotationType) async {
        guard let tab, let viewer, canChange else { return }
        let runs = await viewer.selection()
        guard self.tab === tab else { return }
        if runs.isEmpty {
            host?.setStatus(L10n.t("Select some text first."))
            return
        }
        let look = currentStyle()
        change(AnnotationText.kindName(kind)) { _ = try $0.markup(kind, runs, look) }
        viewer.clearSelection()
    }

    func mark(_ mark: SelectionMark) async {
        switch mark {
        case .highlight: await markup(.highlight)
        case .underline: await markup(.underline)
        case .note: await noteOnSelection()
        case .redact: break
        }
    }

    /// Puts a note at the start of the selected text and opens its field.
    public func noteOnSelection() async {
        guard let tab, let viewer, canChange else { return }
        let runs = await viewer.selection()
        guard self.tab === tab else { return }
        guard let run = runs.first(where: { !$0.quads.isEmpty }), run.page < tab.document.pages.count else {
            host?.setStatus(L10n.t("Select some text first."))
            return
        }
        let corner = viewer.geometry(run.page).toDisplay(run.quads[0].bounds)
        viewer.clearSelection()
        type(.note, run.page, [ViewPoint(corner.x, corner.y)], currentStyle(), L10n.t("Note"))
    }

    /// Types new text for the selected mark.
    public func editSelectedText() {
        if let mark = editTool?.current { editText(of: mark) }
    }

    func editText(of mark: PdfAnnotation) {
        guard let tab, canChange else { return }
        let box = Marker(tab.document, fonts, author: "", date: PanelDates.now()).box(of: mark)
        let area = mark.type == .text ? ViewRect(box.x, box.bottom, 170, 60) : box
        field?.drop()
        compose(tab, mark.pageIndex, area, mark.type == .freeText ? Marker.textOf(mark).size : 12, mark.contents ?? "") { [self] text in
            text == (mark.contents ?? "") || change(L10n.t("Edit text")) { _ = try $0.setText(mark, text) }
        }
    }

    // Delete on a picked corner takes the corner away, not the mark.
    func removePoint(_ mark: PdfAnnotation, _ index: Int) {
        guard let tab, canChange else { return }
        if makeMarker(tab).canRemovePoint(mark, index) {
            change(L10n.t("Remove point")) { _ = try $0.removePoint(mark, index) }
        } else {
            host?.setStatus(L10n.t("That point cannot be removed."))
        }
    }

    /// Adds a corner to the selected polygon: in the middle of the side after the picked corner, or of the longest side when none
    /// is picked. The new corner is picked, so it can be dragged.
    public func addPoint() {
        guard canChange, let tab, let edit = editTool, let mark = edit.current, Marker.plainPolygon(mark),
              let corners = makeMarker(tab).pointsOf(mark) else { return }
        func gap(_ i: Int) -> Double {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            return hypot(b.x - a.x, b.y - a.y)
        }
        let after = edit.pickedVertex >= 0 && edit.pickedVertex < corners.count ? edit.pickedVertex : corners.indices.max { gap($0) < gap($1) } ?? 0
        let a = corners[after], b = corners[(after + 1) % corners.count]
        let middle = ViewPoint((a.x + b.x) / 2, (a.y + b.y) / 2)
        if change(L10n.t("Add point"), { _ = try $0.insertPoint(mark, after: after, at: middle) }) { edit.pickAfterRefresh(after + 1) }
    }

    /// Takes the picked corner from the selected polygon, or the last one when none is picked, so the button works without a pointer.
    public func removePickedPoint() {
        guard let tab, let edit = editTool, let mark = edit.current, let corners = makeMarker(tab).pointsOf(mark) else { return }
        let index = edit.pickedVertex >= 0 ? edit.pickedVertex : corners.count - 1
        edit.clearPick()
        removePoint(mark, index)
    }

    public func deleteSelected() {
        if let mark = editTool?.current { change(L10n.t("Delete")) { $0.delete(mark) } }
    }
}
