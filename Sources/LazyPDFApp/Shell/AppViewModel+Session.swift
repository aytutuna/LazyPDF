import Foundation

// The Mac's "Reopen files from last time". Windows keeps paths only (AppPreferences.ReopenLast); a sandboxed app needs a
// bookmark to read a file again, and the page is kept too.

/// The tabs at quit, in strip order, and which one was active.
public struct LastSession: Equatable {
    public var files: [SessionFile]
    public var active: Int
}

extension AppViewModel {
    public func setReopenLast(_ on: Bool) {
        reopenLast = on
        AppPreferencesStore.update(settings) {
            $0.reopenLast = on
            if !on { $0.lastFiles = [] }
        }
        notifyAll()
    }

    /// Taken before the tabs are closed, since closing them empties the list.
    public func lastSession() -> LastSession {
        let tabs = documents.filter { $0.url != nil }
        let files = tabs.map { SessionFile(path: $0.url!.path, bookmark: bookmarks.make($0.url!), page: $0.pageIndex) }
        let active = activeDocument.flatMap { current in tabs.firstIndex { $0 === current } } ?? 0
        return LastSession(files: files, active: active)
    }

    /// Nothing is kept unless the person asked for it.
    public func keep(_ session: LastSession) {
        let on = reopenLast
        AppPreferencesStore.update(settings) {
            $0.lastFiles = on ? session.files : []
            $0.lastActive = on ? session.active : 0
        }
    }

    /// Opens what `keep` saved. A crash offer or a file that is open already comes first and wins.
    public func reopenLastSession() async {
        let preferences = AppPreferencesStore.load(settings)
        if !preferences.reopenLast || recoveryOffer != nil || !documents.isEmpty { return }
        var opened: [Int: DocumentTab] = [:]
        for (index, file) in preferences.lastFiles.enumerated() {
            let url = file.bookmark.flatMap { bookmarks.resolve($0)?.url } ?? URL(fileURLWithPath: file.path)
            let access = bookmarks.access(url)
            // A file that is gone is skipped quietly; the person did not ask to open it just now.
            if !FileManager.default.fileExists(atPath: url.path) {
                access?.stop()
                continue
            }
            await open(url, access: access)
            guard let tab = tab(of: url) else { continue }
            tab.pageIndex = min(max(file.page, 0), max(tab.pageCount - 1, 0))
            opened[index] = tab
        }
        if let active = opened[preferences.lastActive] { select(active) }
    }
}
