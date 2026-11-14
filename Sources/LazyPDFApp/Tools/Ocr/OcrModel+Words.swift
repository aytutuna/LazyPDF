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
        keptWords = keptWords.filter { $0.value.tab.tab != nil }
        guard let tab, let back = keptWords.removeValue(forKey: ObjectIdentifier(tab)) else { return }
        var word = back.word
        if back.revision != tab.revision {
            guard let origin = back.origin, let index = Self.find(tab, word.page, origin) else {
                dropWaiting(tab)
                return
            }
            word = WordRef(word.page, index)
        }
        picked = word
        pickedOrigin = back.origin
        draft = back.text
        inPanel = true
        tab.pendingWords = 1
        mark(word)
    }

    // The word is looked for by its page, box and text, since the numbers of the words move with the layer.
    private static func find(_ tab: DocumentTab, _ page: Int, _ origin: OcrLayerWord) -> Int? {
        guard page < tab.pageCount, let words = try? PdfOcrLayer.words(tab.document, tab.document.pages[page]) else { return nil }
        return words.first { $0.text == origin.text && $0.box == origin.box }?.index
    }

    private func dropWaiting(_ tab: DocumentTab) {
        tab.pendingWords = 0
        host?.setStatus(L10n.t("The word you were correcting is no longer in the file, so the correction was dropped."))
    }

    func detachWords() {
        if let tab, tab.pendingWords > 0, let word = picked {
            keptWords[ObjectIdentifier(tab)] = (WeakTab(tab: tab), word, pickedOrigin, draft, tab.revision)
        } else {
            tab?.pendingWords = 0
        }
        viewWatch?.stop()
        viewWatch = nil
        shown = [:]
        field = nil
        waiting = false
        correctedRevision = nil
        words = []
        picked = nil
        pickedOrigin = nil
        inPanel = false
        draft = ""
        touchStart = nil
    }

    // The words and the marks are for one revision of the file; the next change builds them again.
    func refreshWords() {
        let held = (tab?.pendingWords ?? 0) > 0
        hideMarks()
        showMarks()
        guard let now = picked else { return }
        if held, let tab, let origin = pickedOrigin, let index = Self.find(tab, now.page, origin) {
            picked = WordRef(now.page, index)
        } else if held || !(shown[now.page].map { now.index < $0.count } ?? false) {
            // A word that cannot be found leaves nothing for the box to apply to.
            picked = nil
            pickedOrigin = nil
            inPanel = false
            if held, let tab { dropWaiting(tab) }
        }
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
        if word != nil { field?.finish() }
        tab?.pendingWords = 0
        if let old = picked { unmark(old) }
        picked = nil
        pickedOrigin = nil
        inPanel = false
        if let word, let found = shown[word.page]?.first(where: { $0.index == word.index }) {
            picked = word
            pickedOrigin = found
            draft = found.text
            mark(word)
            if edit { editWord(word, found) }
        } else {
            draft = ""
            field?.drop()
        }
    }

    /// The panel's list chose a word of the page in view. It is corrected in a box of the panel, since the panel may cover
    /// the page or the field be out of sight; the page scrolls to show the word.
    public func pickFromList(_ word: OcrLayerWord) {
        let page = viewer?.pageIndex ?? 0
        let revision = tab?.revision
        field?.finish()
        // A word removed just now renumbers the list, so the row tapped no longer names the word it showed.
        guard tab?.revision == revision else { return }
        pick(WordRef(page, word.index))
        guard picked != nil else { return }
        inPanel = true
        viewer?.reveal(page, ViewRect(word.box.x, word.box.y, word.box.width, word.box.height))
    }

    /// Puts what was typed in the panel's box into the file.
    public func applyDraft() {
        guard inPanel, let ref = picked else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = text
        if text != pickedText { apply(ref, text) }
    }

    public var pickedText: String? {
        guard let now = picked else { return nil }
        return shown[now.page]?.first { $0.index == now.index }?.text
    }

    private func editWord(_ ref: WordRef, _ word: OcrLayerWord) {
        guard let viewer else { return }
        let area = ViewRect(word.box.x, word.box.y, word.box.width, word.box.height)
        let look = OverlayTextLook(size: max(word.box.height * 0.8, 6))
        fieldSerial += 1
        let mine = fieldSerial
        let made = OverlayField(Self.fieldId, area: area, text: word.text, look: look, wraps: false, label: L10n.t("Corrected word")) { [weak self] text in
            guard let self else { return }
            // A field on another page ends after the next one has opened, and must not forget that one.
            if self.fieldSerial == mine { self.field = nil }
            guard let text else { return }
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if typed != word.text { self.apply(ref, typed) }
        }
        field = viewer.overlay(ref.page).open(made)
    }

    // A word typed and not yet in the file goes in before the file is saved, undone or closed. A signed file keeps it in the
    // panel's box, as Measure keeps its readings: nothing is written without the user's answer, and the close question names it.
    // The word stays with its tab when another tab or tool is shown, so moving on loses nothing.
    public func handIn() -> Bool {
        waiting = false
        keepsSigned = true
        field?.finish()
        applyDraft()
        keepsSigned = false
        tab?.pendingWords = waiting ? 1 : 0
        return true
    }

    private func apply(_ word: WordRef, _ text: String) {
        guard let tab, let host else { return }
        let go: @MainActor () -> Void = { [weak self] in
            if self?.tab === tab { self?.applyNow(tab, host, word, text) }
        }
        if keepsSigned && tab.document.isSigned && OcrWork.refusal(tab.document) == nil {
            keep(word, text)
        } else if OcrWork.cleared(tab, host, go: go) {
            applyNow(tab, host, word, text)
        } else {
            waiting = OcrWork.refusal(tab.document) == nil
        }
    }

    // The text moves into the panel's box, where its button still applies it after the usual question.
    private func keep(_ word: WordRef, _ text: String) {
        if picked != word {
            if let old = picked { unmark(old) }
            picked = word
            pickedOrigin = shown[word.page]?.first { $0.index == word.index }
            mark(word)
        }
        draft = text
        inPanel = true
        waiting = true
    }

    private func applyNow(_ tab: DocumentTab, _ host: ToolHost, _ word: WordRef, _ text: String) {
        tab.pendingWords = 0
        let before = tab.revision
        ChangeGate.guarded(host, L10n.t("Correct word")) { try OcrWork.correct(tab, word.page, word.index, text) }
        if tab.revision != before {
            correctedRevision = tab.revision
            // The words are numbered again from the file, and the next press must hit the new numbers.
            refreshWords()
        }
        if text.isEmpty { pick(nil) }
    }
}

extension OcrModel: PagePointerTool {
    public var cursor: PointerCursor? { nil }

    // A mouse is the tool's only over a word, so selecting text, panning and links stay with the viewer. A finger scrolls
    // unless the person asked to correct by touch, since word boxes cover most of a page of text.
    public func takes(_ pointer: PagePointer) -> Bool {
        if pointer.touch && !touchCorrects { return false }
        return word(at: pointer) != nil
    }

    public func press(_ pointer: PagePointer) {
        field?.finish()
        guard let word = word(at: pointer) else { return }
        if pointer.touch {
            touchStart = (word, pointer.view)
        } else {
            pick(word, edit: true)
        }
    }

    public func move(_ pointer: PagePointer) {}

    // A finger that dragged away does not open the keyboard.
    public func release(_ pointer: PagePointer) {
        guard let start = touchStart else { return }
        touchStart = nil
        if hypot(pointer.view.x - start.at.x, pointer.view.y - start.at.y) <= 10 { pick(start.word, edit: true) }
    }

    public func cancel() { touchStart = nil }

    private func word(at pointer: PagePointer) -> WordRef? {
        guard showWords, let found = shown[pointer.page], let matrix = viewer?.pageToView(pointer.page) else { return nil }
        let reach = (pointer.touch ? 8.0 : 0.0) / ViewScale.of(matrix)
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
