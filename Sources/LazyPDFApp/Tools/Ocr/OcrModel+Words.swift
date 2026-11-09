import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Ocr/OcrPanel.Words.cs: the words of the text layer marked on the pages in view, the same
// words as a list for whoever cannot point at them, and the correction of the one that was picked, typed in a field on the page.

/// A word of the text layer: its page and its index in that page's layer.
public struct WordRef: Equatable {
    public let page: Int
    public let index: Int

    public init(_ page: Int, _ index: Int) {
        self.page = page
        self.index = index
    }
}

extension OcrModel {
    static let markPrefix = "ocr.w."
    static let fieldId = "ocr.word"

    func attachWords() {
        guard let viewer else { return }
        viewer.pointerTool = self
        viewWatch = ObservationWatch(track: { _ = viewer.viewRevision; _ = viewer.visiblePages; _ = viewer.pageIndex },
                                     changed: { [weak self] in self?.showMarks() })
        showMarks()
    }

    func detachWords() {
        viewWatch?.stop()
        viewWatch = nil
        shown = [:]
        field = nil
        waiting = false
        correctedRevision = nil
        words = []
        picked = nil
    }

    // The words and the marks are for one revision of the file; the next change builds them again.
    func refreshWords() {
        hideMarks()
        showMarks()
        if let now = picked, !(shown[now.page].map { now.index < $0.count } ?? false) { picked = nil }
        if let now = picked { mark(now) }
    }

    func showMarks() {
        guard let tab, let viewer, showWords else { return }
        let visible = viewer.visiblePages
        for page in shown.keys where !visible.contains(page) {
            viewer.overlay(page).remove(prefix: Self.markPrefix + "\(page).")
            shown[page] = nil
        }
        for page in visible where shown[page] == nil && page < tab.pageCount {
            let found = (try? PdfOcrLayer.words(tab.document, tab.document.pages[page])) ?? []
            shown[page] = found
            let overlay = viewer.overlay(page)
            for word in found { overlay.set(item(page, word, picked: false)) }
        }
        if let now = picked { mark(now) }
        fillWordList()
    }

    func hideMarks() {
        if let viewer {
            for page in shown.keys { viewer.overlay(page).remove(prefix: Self.markPrefix + "\(page).") }
        }
        shown = [:]
        fillWordList()
    }

    // The words of the page in view, for the panel's list.
    private func fillWordList() {
        let page = viewer?.pageIndex ?? 0
        let list = showWords ? shown[page] ?? [] : []
        if list.count != words.count || zip(list, words).contains(where: { $0.index != $1.index || $0.text != $1.text }) { words = list }
    }

    private func item(_ page: Int, _ word: OcrLayerWord, picked: Bool) -> OverlayItem {
        OverlayItem(Self.markPrefix + "\(page).\(word.index)", .rect(ViewRect(word.box.x, word.box.y, word.box.width, word.box.height)),
                    style: OverlayStyle(stroke: .accent, fill: picked ? OverlayColor.accent.opacity(0.19) : nil, lineWidth: picked ? 2 : 0.75),
                    opacity: picked ? 1 : 0.8)
    }

    private func mark(_ word: WordRef) {
        guard let viewer, let found = shown[word.page]?.first(where: { $0.index == word.index }) else { return }
        viewer.overlay(word.page).set(item(word.page, found, picked: true))
    }

    private func unmark(_ word: WordRef) {
        guard let viewer, let found = shown[word.page]?.first(where: { $0.index == word.index }) else { return }
        viewer.overlay(word.page).set(item(word.page, found, picked: false))
    }

    /// Chooses a word for correction; with `edit` its text opens in a field over the word.
    public func pick(_ word: WordRef?, edit: Bool = false) {
        if let old = picked { unmark(old) }
        picked = nil
        if let word, let found = shown[word.page]?.first(where: { $0.index == word.index }) {
            picked = word
            mark(word)
            if edit { editWord(word, found) }
        } else {
            field?.drop()
        }
    }

    /// The panel's list chose a word of the page in view.
    public func pickFromList(_ word: OcrLayerWord) {
        pick(WordRef(viewer?.pageIndex ?? 0, word.index), edit: true)
    }

    public var pickedText: String? {
        guard let now = picked else { return nil }
        return shown[now.page]?.first { $0.index == now.index }?.text
    }

    private func editWord(_ ref: WordRef, _ word: OcrLayerWord) {
        guard let viewer else { return }
        let area = ViewRect(word.box.x, word.box.y, word.box.width, word.box.height)
        let look = OverlayTextLook(size: max(word.box.height * 0.8, 6))
        let made = OverlayField(Self.fieldId, area: area, text: word.text, look: look, wraps: false, label: L10n.t("Corrected word")) { [weak self] text in
            guard let self else { return }
            self.field = nil
            if let text { self.apply(ref, text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        field = viewer.overlay(ref.page).open(made)
    }

    // A word typed and not yet in the file goes in before the file is saved, undone or closed. False while a signed file waits
    // for its answer.
    public func handIn() -> Bool {
        waiting = false
        field?.finish()
        return !waiting
    }

    private func apply(_ word: WordRef, _ text: String) {
        guard let tab, let host else { return }
        let go: @MainActor () -> Void = { [weak self] in
            if self?.tab === tab { self?.applyNow(tab, host, word, text) }
        }
        if OcrWork.cleared(tab, host, go: go) {
            applyNow(tab, host, word, text)
        } else {
            waiting = OcrWork.refusal(tab.document) == nil
        }
    }

    private func applyNow(_ tab: DocumentTab, _ host: ToolHost, _ word: WordRef, _ text: String) {
        let before = tab.revision
        ChangeGate.guarded(host, L10n.t("Correct word")) { try OcrWork.correct(tab, word.page, word.index, text) }
        if tab.revision != before { correctedRevision = tab.revision }
        if text.isEmpty { pick(nil) }
    }
}

extension OcrModel: PagePointerTool {
    public var cursor: PointerCursor? { nil }

    // A finger over a word is the tool's; anywhere else it scrolls the page.
    public func takes(_ pointer: PagePointer) -> Bool {
        word(at: pointer, slop: 8) != nil
    }

    public func press(_ pointer: PagePointer) {
        if let word = word(at: pointer, slop: 24) { pick(word, edit: true) }
    }

    public func move(_ pointer: PagePointer) {}
    public func release(_ pointer: PagePointer) {}
    public func cancel() {}

    private func word(at pointer: PagePointer, slop: Double) -> WordRef? {
        guard showWords, let found = shown[pointer.page], let matrix = viewer?.pageToView(pointer.page) else { return nil }
        let reach = slop / ViewScale.of(matrix)
        var best: (word: WordRef, distance: Double)?
        for word in found {
            let box = word.box
            let dx = max(box.x - pointer.point.x, 0, pointer.point.x - (box.x + box.width))
            let dy = max(box.y - pointer.point.y, 0, pointer.point.y - (box.y + box.height))
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= reach && distance < (best?.distance ?? .infinity) { best = (WordRef(pointer.page, word.index), distance) }
        }
        return best?.word
    }
}
