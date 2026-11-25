import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/DocumentRegistry.cs.

/// The view models of every window of the app, so a file is held by one tab however it was asked for and a tab can move
/// from one window to another. One per process, used on the main actor.
@MainActor
public final class DocumentRegistry {
    public private(set) var models: [AppViewModel] = []

    public init() {}

    func add(_ model: AppViewModel) {
        if !models.contains(where: { $0 === model }) { models.append(model) }
    }

    public func remove(_ model: AppViewModel) {
        models.removeAll { $0 === model }
    }

    /// The window whose strip has the tab with this id.
    public func find(_ id: UUID) -> AppViewModel? {
        models.first { model in model.documents.contains { $0.id == id } }
    }

    /// The tab that holds the file in a window other than `model`.
    func tab(of url: URL, besides model: AppViewModel) -> (AppViewModel, DocumentTab)? {
        for other in models where other !== model {
            if let tab = other.tab(of: url) { return (other, tab) }
        }
        return nil
    }

    /// True when another window is reading the file or waits for its password.
    func isOpening(_ url: URL, besides model: AppViewModel) -> Bool {
        let key = RecentFiles.folded(url)
        return models.contains { other in
            other !== model && (other.opening.contains(key) || other.pending.contains { AppViewModel.same($0.source.url, url) })
        }
    }

    /// What the next start reopens when the whole app ends: the files of every window, the first window's first.
    public func session() -> LastSession {
        var files: [SessionFile] = []
        var active = 0
        var found = false
        for model in models {
            let mine = model.lastSession()
            if !found, model.activeDocument?.url != nil {
                active = files.count + mine.active
                found = true
            }
            files += mine.files
        }
        return LastSession(files: files, active: active)
    }

    /// Moves the tab itself from one window to another, inserted at `index`; nothing is copied, so the edits, undo history,
    /// recovery copy and password go with it. A refusal says why in the source window and leaves the tab where it was.
    /// `targetFree` is the target window's own check (a sheet or a panel of its own is up).
    @discardableResult
    public func transfer(_ tab: DocumentTab, from: AppViewModel, to: AppViewModel, at index: Int, targetFree: Bool = true) -> Bool {
        if from === to || find(tab.id) !== from { return false }
        if let reason = from.releaseRefusal(tab) ?? to.adoptRefusal(windowFree: targetFree) {
            from.showNotice(L10n.t("Tab not moved"), reason)
            return false
        }
        guard from.handInForRelease(tab), to.handInForSwitch() else {
            from.showNotice(L10n.t("Tab not moved"), L10n.t("The other window is busy. Try again when it is done."))
            return false
        }
        let restoreTarget = to.keepView()
        let restoreSource = from.keepView()
        let at = from.index(of: tab) ?? 1
        from.release(tab)
        if to.adopt(tab, at: index) { return true }
        // Back the way it came: it is in no strip now, so it can never be in two.
        if to.index(of: tab) != nil { to.release(tab) }
        from.restore(tab, at: at)
        restoreTarget()
        restoreSource()
        from.showProblem(Problem(L10n.t("Tab not moved"), L10n.t("Something went wrong, so {0} stays in this window.", tab.title)))
        return false
    }
}
