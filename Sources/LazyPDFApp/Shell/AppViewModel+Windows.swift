import Foundation
import LazyPDFKit

// Follows CanRelease, CanAdopt, Release and Adopt of windows/LazyPDF.App/AppViewModel.Documents.cs: a tab moves to another
// window as the object it is, so its edits, undo history, renderer, recovery copy and password go with it.

extension AppViewModel {
    /// Why the tab cannot leave this window now, or nil. It cannot while a job runs, it is being reloaded or replaced, a
    /// question about closing it is up, or its comparison is open.
    func releaseRefusal(_ tab: any StripTab) -> String? {
        guard let document = tab as? DocumentTab, index(of: document) != nil else { return L10n.t("The Home tab stays where it is.") }
        if isBusy || actionRunning || MarkWork.shared.running {
            return L10n.t("Wait for the job to end, or cancel it, then move the tab.")
        }
        if reloading.contains(ObjectIdentifier(document)) || pending.contains(where: { $0.replacing === document }) {
            return L10n.t("{0} is being reloaded. Try again in a moment.", document.title)
        }
        let queued = exiting && (document.isDirty || document.hasUnappliedWork)
        if closeQuestion === document || queued { return L10n.t("Answer the question about {0} first.", document.title) }
        if toolState.compare[document]?.window != nil { return L10n.t("Close the comparison first.") }
        return nil
    }

    public func canRelease(_ tab: any StripTab) -> Bool {
        releaseRefusal(tab) == nil
    }

    /// True while a file is being opened here, so an emptied window is not closed under it.
    public var isOpening: Bool { !opening.isEmpty }

    /// The checks that belong to the window a tab leaves, run before a window is made for it. False, with the reason shown
    /// here, when it stays.
    public func mayRelease(_ tab: DocumentTab) -> Bool {
        if let reason = releaseRefusal(tab) {
            showNotice(L10n.t("Tab not moved"), reason)
            return false
        }
        return handInForRelease(tab)
    }

    /// Why a tab cannot arrive in this window now, or nil. `windowFree` is the shell's own answer: false while one of its
    /// sheets is up. Typed text in the open tool is asked in `DocumentRegistry.transfer`, since asking hands it in.
    func adoptRefusal(windowFree: Bool = true) -> String? {
        let free = windowFree && !sheetOpen && !isBlocked && !exiting && !actionRunning
        return free ? nil : L10n.t("The other window is busy. Try again when it is done.")
    }

    public func canAdopt(windowFree: Bool = true) -> Bool {
        adoptRefusal(windowFree: windowFree) == nil
    }

    // Typed text goes into the document it was typed for, which is the moved one only when the panels show it.
    func handInForRelease(_ tab: DocumentTab) -> Bool {
        tab !== activeDocument || handIn()
    }

    /// Takes the tab out of the strip without closing it. Returns where it was; nil when it is not here.
    @discardableResult
    func release(_ tab: DocumentTab) -> Int? {
        guard let at = index(of: tab) else { return nil }
        released?(tab)
        tab.changed = nil
        if activeTab === tab { activeTab = strip[at + 1 < strip.count ? at + 1 : at - 1] }
        if lastDocument === tab { lastDocument = documents.last { $0 !== tab } }
        dropAction()
        if messageTab === tab {
            message = nil
            messageTab = nil
        }
        warnedAboutDisk[ObjectIdentifier(tab)] = nil
        strip.remove(at: at)
        rememberView(tab)
        notifyAll()
        return at
    }

    /// Puts a tab released by another window into the strip at `index`, after the Home tab at the earliest, and shows it.
    /// False, with nothing changed, when the tab is closed or already here.
    @discardableResult
    func adopt(_ tab: DocumentTab, at index: Int) -> Bool {
        if tab.isDisposed || self.index(of: tab) != nil { return false }
        insert(tab, at: index)
        show(tab)
        return true
    }

    // A move that failed: the tab goes back to the window it came from, whatever state the tab is in.
    func restore(_ tab: DocumentTab, at index: Int) {
        if self.index(of: tab) == nil { insert(tab, at: index) }
    }

    private func insert(_ tab: DocumentTab, at index: Int) {
        tab.changed = { [weak self] in self?.notifyAll() }
        strip.insert(tab, at: min(max(index, 1), strip.count))
        lastDocument = tab
        notifyAll()
    }

    /// Notes which tab is in view and what the info bar says, for a move that fails to put back.
    func keepView() -> () -> Void {
        let active = activeTab
        let last = lastDocument
        let note = message
        let noteTab = messageTab
        return { [self] in
            if index(of: active) != nil { activeTab = active }
            if last.map({ index(of: $0) != nil }) ?? true { lastDocument = last }
            message = note
            messageTab = noteTab
            notifyAll()
        }
    }
}
