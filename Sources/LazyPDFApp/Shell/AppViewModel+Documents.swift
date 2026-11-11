import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/AppViewModel.Documents.cs. Opening, saving and closing documents: the dialog-free half of
// what the File menu does, the password and certificate questions, undo and redo, and noticing that a file changed on disk.
//
// The file must be readable when it is handed in: the platform shell starts the security-scoped access before it calls
// `open` and passes the grant along. The shell stops it when the file is not kept (already open, unreadable, cancelled
// or refused) and otherwise the tab stops it when it is disposed.

/// What the password overlay shows: which file, whether it wants a certificate, and why the last try failed.
public struct OpenRequest {
    public let name: String
    public let needsCertificate: Bool
    public let attempts: Int
    public let problem: String?
    public let certificates: [CertificateChoice]
}

@MainActor
final class PendingOpen {
    let source: OpenSource
    /// The recovery entry the bytes came from; it stays until a tab holds them.
    let recovery: UUID?
    /// The tab this open takes the place of: a reload.
    let replacing: DocumentTab?
    var needsCertificate = false
    var certificates: [CertificateChoice] = []
    var attempts = 0
    var problem: String?
    var submitting = false
    var cancelled = false
    var access: FileAccess?

    init(_ source: OpenSource, recovery: UUID? = nil, replacing: DocumentTab? = nil, access: FileAccess? = nil) {
        self.source = source
        self.recovery = recovery
        self.replacing = replacing
        self.access = access
    }

    func release() {
        access?.stop()
        access = nil
    }
}

extension AppViewModel {
    /// The file that is waiting for a password or a certificate, if any.
    public var passwordRequest: OpenRequest? {
        _ = version
        guard let first = pending.first else { return nil }
        return OpenRequest(name: first.source.title, needsCertificate: first.needsCertificate, attempts: first.attempts,
                           problem: first.problem, certificates: first.certificates)
    }

    public var canUndo: Bool {
        _ = version
        return activeDocument?.session.canUndo == true
    }

    public var canRedo: Bool {
        _ = version
        return activeDocument?.session.canRedo == true
    }

    public var undoLabel: String? {
        _ = version
        return activeDocument?.session.undoLabel
    }

    public var redoLabel: String? {
        _ = version
        return activeDocument?.session.redoLabel
    }

    public func open(_ urls: [URL]) async {
        for url in urls { await open(url) }
    }

    /// Opens a PDF made elsewhere (a scan, a merge) as a document with unsaved changes.
    public func openNew(_ pdf: [UInt8], title: String, password: String? = nil, certificate: CertificateChoice? = nil) async {
        await open(PendingOpen(OpenSource(bytes: pdf, url: nil, title: title, made: true)), password: password, certificate: certificate)
    }

    /// Opens a recent file, starting the access its bookmark gives.
    public func openRecent(_ item: RecentItem) async {
        await open(item.url, access: bookmarks.access(item.url))
    }

    /// A file the system or a drop hands over opens at once, or waits until the job, question or message in the way is gone.
    public func openOrHold(_ url: URL, access: FileAccess?) async {
        if !holdsFiles {
            await open(url, access: access)
            return
        }
        if held.isEmpty { heldMessage = messageSerial }
        held.append((url, access))
        setStatus(L10n.t("Will open when you are done here."))
    }

    public func releaseHeld() async {
        if holdsFiles || held.isEmpty { return }
        let files = held
        held = []
        for file in files { await open(file.url, access: file.access) }
    }

    public func open(_ url: URL, access: FileAccess? = nil) async {
        var kept = false
        defer { if !kept { access?.stop() } }
        let name = url.lastPathComponent
        if let already = tab(of: url) {
            select(already)
            return
        }
        let key = RecentFiles.folded(url)
        if pending.contains(where: { Self.same($0.source.url, url) }) || !opening.insert(key).inserted { return }
        defer { opening.remove(key) }
        let source: OpenSource
        do {
            let opener = opener
            source = try await Task.detached { try opener.read(url) }.value
        } catch {
            showProblem(Problems.open(error, name))
            if StoreFiles.isNoSuchFile(error) {
                recentFiles.remove(url)
                recent = buildRecent()
                notifyAll()
            }
            return
        }
        kept = true
        await open(PendingOpen(source, access: access), password: nil, certificate: nil)
    }

    /// Opens a copy the system left in the app's own folders as a document with no file, so saving asks for a name.
    public func openCopy(_ url: URL, access: FileAccess?) async {
        defer { access?.stop() }
        let source: OpenSource
        do {
            let opener = opener
            source = try await Task.detached { try opener.read(url, asCopy: true) }.value
        } catch {
            showProblem(Problems.open(error, url.lastPathComponent))
            return
        }
        await open(PendingOpen(source), password: nil, certificate: nil)
    }

    public func tab(of url: URL) -> DocumentTab? {
        documents.first { Self.same($0.url, url) }
    }

    static func same(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return RecentFiles.sameFile(a, b)
    }

    public func submitPassword(_ password: String) async {
        if let first = pending.first { await open(first, password: password, certificate: nil) }
    }

    public func submitCertificate(_ choice: CertificateChoice) async {
        if let first = pending.first { await open(first, password: nil, certificate: choice) }
    }

    /// Gives up on the file that asked for a password or a certificate. A recovery copy it came from is kept.
    public func cancelPending() {
        guard let first = pending.first else { return }
        first.cancelled = true
        first.release()
        pending.removeFirst()
        notifyAll()
    }

    func open(_ pending: PendingOpen, password: String?, certificate: CertificateChoice?) async {
        if pending.submitting { return }
        pending.submitting = true
        defer { pending.submitting = false }
        await openCore(pending, password, certificate)
    }

    private func openCore(_ pending: PendingOpen, _ password: String?, _ certificate: CertificateChoice?) async {
        let source = pending.source
        let session: PdfEditSession
        do {
            let keys = certificates
            session = try await Task.detached {
                if let certificate { return try keys.open(source.bytes, certificate) }
                return try PdfEditSession.open(source.bytes, password: password)
            }.value
        } catch let error as PdfReadException where error.problem == .passwordRequired || error.problem == .certificateRequired {
            if pending.cancelled { return }
            let asked = self.pending.contains { $0 === pending }
            if !asked { self.pending.append(pending) }
            pending.needsCertificate = error.problem == .certificateRequired
            pending.certificates = pending.needsCertificate ? certificates.choices() : []
            pending.problem = asked
                ? (pending.needsCertificate ? L10n.t("That certificate does not open this file.") : L10n.t("That password is not right."))
                : nil
            if asked { pending.attempts += 1 }
            notifyAll()
            return
        } catch {
            self.pending.removeAll { $0 === pending }
            pending.release()
            showProblem(Problems.open(error, source.title))
            return
        }

        if pending.cancelled { return }
        self.pending.removeAll { $0 === pending }
        if session.document.pages.count == 0 {
            pending.release()
            showProblem(Problem(L10n.t("Nothing to show"), L10n.t("{0} has no pages.", source.title)))
            return
        }
        let url = source.url
        let make = renderers
        let recovery = recovery
        let unsaved = source.made || pending.recovery != nil
        let (renderer, loaded) = await Task.detached {
            let renderer = make()
            return (renderer, renderer.load(session, password))
        }.value
        // A second reload of one tab, or an open that lost a race, finds the file in a tab already: it must not make another.
        let taken: Bool
        if let old = pending.replacing {
            taken = index(of: old) == nil
        } else {
            taken = url.map { self.tab(of: $0) != nil } ?? false
        }
        if taken {
            renderer.close()
            pending.release()
            return
        }
        let tab = DocumentTab(session: session, renderer: renderer, url: url, title: source.title, password: password,
                              recovery: recovery, unsaved: unsaved, known: source.stamp, diskHash: source.hash, certificate: certificate, loaded: loaded,
                              bookmarks: bookmarks, access: pending.access, writer: fileWriter, readOnly: source.readOnly)
        pending.access = nil
        tab.changed = { [weak self] in self?.notifyAll() }
        if let old = pending.replacing, let at = index(of: old) {
            replace(at, with: tab)
        } else {
            strip.append(tab)
        }
        if let entry = pending.recovery { await Task.detached { recovery.delete(entry) }.value }
        if let url, pending.recovery == nil, pending.replacing == nil {
            recentFiles.add(url)
            recent = buildRecent()
        }
        if let was = pending.replacing {
            tab.pageIndex = min(was.pageIndex, tab.pageCount - 1)
            tab.zoom = was.zoom
            tab.fit = was.fit
        }
        select(tab)
        if let note = source.note {
            showNotice(L10n.t("Opened with changes"), note)
        } else if tab.readOnly {
            showNotice(L10n.t("File is read-only"), L10n.t("{0} is read-only. You can work on it, but save your changes with Save as.", tab.title))
        } else if !tab.canDraw {
            showNotice(L10n.t("Pages cannot be shown"), L10n.t("{0} opens for editing, but its pages cannot be shown here.", tab.title))
        }
    }

    // The tab takes the old one's place in the strip and, if the old one was in view, in the window.
    private func replace(_ index: Int, with tab: DocumentTab) {
        guard let old = strip[index] as? DocumentTab else { return }
        strip[index] = tab
        if lastDocument === old { lastDocument = tab }
        old.changed = nil
        tab.adoptAccess(from: old)
        warnedAboutDisk[ObjectIdentifier(old)] = nil
        old.dispose()
    }

    /// True when `tab` was made from pictures or text, or has no file yet, or is read-only, so saving needs a name.
    public static func needsName(_ tab: DocumentTab) -> Bool {
        tab.url == nil || tab.readOnly
    }

    /// Saves over the file the tab was read from. Call `needsName` first; false also when the save failed and the info bar
    /// says why. With `closeAfter`, the Save anyway button closes the tab too, and goes on with a quit that was waiting.
    @discardableResult
    public func save(_ tab: DocumentTab, closeAfter: Bool = false) -> Bool {
        guard let url = tab.url else { return false }
        if tab.changedOnDisk && FileManager.default.fileExists(atPath: url.path) {
            if let found = tab.onDisk, tab.isOnlyTouched(found) {
                tab.acceptDiskState()
                return write(tab) { try tab.save() }
            }
            let wasExiting = exiting
            showNotice(L10n.t("File changed"), L10n.t("{0} was changed by another program. Saving now replaces that version with yours.", tab.title),
                       NoticeAction(L10n.t("Save anyway")) { [weak self] in
                           guard let self, write(tab, { try tab.save() }), closeAfter else { return }
                           exiting = wasExiting
                           close(tab)
                       })
            return false
        }
        return write(tab) { try tab.save() }
    }

    @discardableResult
    public func saveAs(_ tab: DocumentTab, _ url: URL) -> Bool {
        !openElsewhere(tab, url) && write(tab) { try tab.saveAs(url) }
    }

    @discardableResult
    public func saveCompact(_ tab: DocumentTab, _ url: URL) -> Bool {
        guard !openElsewhere(tab, url), write(tab, { try tab.saveCompact(url) }) else { return false }
        showNotice(L10n.t("Saved compact"), L10n.t("{0} was saved without its history, so the earlier steps can no longer be undone.", tab.title))
        return true
    }

    // Two tabs on one file would each save over the other.
    private func openElsewhere(_ tab: DocumentTab, _ url: URL) -> Bool {
        guard let other = self.tab(of: url), other !== tab else { return false }
        showProblem(Problem(L10n.t("File is open"), L10n.t("{0} is open in another tab. Close that tab first, or pick another name.", other.title)))
        return true
    }

    private func write(_ tab: DocumentTab, _ save: () throws -> Void) -> Bool {
        do {
            try save()
        } catch is PdfPermissionException {
            showProblem(Problems.restricted())
            return false
        } catch {
            showProblem(Problems.save(error, tab.title))
            return false
        }
        warnedAboutDisk[ObjectIdentifier(tab)] = nil
        if let url = tab.url { recentFiles.add(url) }
        recent = buildRecent()
        message = nil
        setStatus(L10n.t("Saved {0}.", tab.title))
        return true
    }

    public func undo() {
        if let tab = activeDocument, (try? tab.undo()) == true { notifyAll() }
    }

    public func redo() {
        if let tab = activeDocument, (try? tab.redo()) == true { notifyAll() }
    }

    /// Closes the tab if it has nothing unsaved and no redaction marks waiting; otherwise sets `closeQuestion` and returns
    /// false.
    @discardableResult
    public func requestClose(_ tab: DocumentTab) -> Bool {
        if waitForJob() { return false }
        if tab === activeDocument && !handIn() { return false }
        if !tab.isDirty && tab.pendingMarks == 0 {
            close(tab)
            return true
        }
        select(tab)
        closeQuestion = tab
        notifyAll()
        return false
    }

    /// Closes the tab and lets go of what it holds. Whatever was unsaved is lost.
    public func close(_ tab: DocumentTab) {
        guard let at = index(of: tab) else { return }
        let wasActive = activeTab === tab
        strip.remove(at: at)
        if wasActive { activeTab = strip[min(at, strip.count - 1)] }
        if lastDocument === tab { lastDocument = documents.last }
        if closeQuestion === tab { closeQuestion = nil }
        dropAction()
        warnedAboutDisk[ObjectIdentifier(tab)] = nil
        tab.changed = nil
        tab.dispose()
        notifyAll()
        if exiting { _ = continueExit(raise: true) }
    }

    /// The answer to `closeQuestion` that keeps the document open.
    public func cancelClose() {
        closeQuestion = nil
        exiting = false
        notifyAll()
    }

    /// Moves a document tab to `index` in the strip; the Home tab stays first.
    public func moveTab(_ tab: DocumentTab, to index: Int) {
        guard let from = self.index(of: tab) else { return }
        let target = min(max(index, 1), strip.count - 1)
        if from < 1 || from == target { return }
        let moved = strip.remove(at: from)
        strip.insert(moved, at: target)
        notifyAll()
    }

    /// True when the window can close now; otherwise asks about the first document with unsaved changes and goes on from
    /// there.
    public func requestExit() -> Bool {
        if waitForJob() { return false }
        if !handIn() { return false }
        exiting = true
        return !continueExit(raise: false)
    }

    /// Has the open tool put what is typed into the document; false when it waits for an answer first.
    public func handIn() -> Bool {
        handInTyping?() ?? true
    }

    // A job edits the document off the main actor, so what is in it now is not something to save or to throw away.
    private func waitForJob() -> Bool {
        if !isBusy && !actionRunning && !MarkWork.shared.running { return false }
        showNotice(L10n.t("Still working"), L10n.t("Wait for the job to end, or cancel it, then close."))
        return true
    }

    private func continueExit(raise: Bool) -> Bool {
        if let dirty = documents.first(where: { $0.isDirty || $0.pendingMarks > 0 }) {
            select(dirty)
            closeQuestion = dirty
            notifyAll()
            return true
        }
        for tab in documents { tab.dispose() }
        exiting = false
        if raise { exitRequested?() }
        return false
    }

    /// Looks at the active document's file: when another program changed or removed it, the info bar says so (once for each
    /// state the file is found in). Called when the window comes forward and when a tab is picked.
    public func checkDisk() {
        guard let tab = activeDocument, let url = tab.url, tab.changedOnDisk else { return }
        let found = tab.onDisk
        if let found, tab.isOnlyTouched(found) {
            tab.acceptDiskState()
            return
        }
        let key = ObjectIdentifier(tab)
        if let seen = warnedAboutDisk[key], seen == found { return }
        warnedAboutDisk[key] = .some(found)
        if !FileManager.default.fileExists(atPath: url.path) {
            showNotice(L10n.t("File is gone"), L10n.t("{0} was moved or deleted. Save it again to keep your work.", tab.title))
            return
        }
        let text = tab.isDirty
            ? L10n.t("{0} was changed by another program. Opening that version drops your unsaved changes.", tab.title)
            : L10n.t("{0} was changed by another program.", tab.title)
        showNotice(L10n.t("File changed"), text, NoticeAction(L10n.t("Open that version")) { [weak self] in
            Task { _ = await self?.tryReload(tab) }
        })
    }

    public func reload(_ tab: DocumentTab) async {
        _ = await tryReload(tab)
    }

    /// Reads the file again from disk and, once that worked, puts it in the place of the tab, keeping its page and zoom;
    /// unsaved changes are dropped then, not before. False when the tab was not replaced.
    public func tryReload(_ tab: DocumentTab) async -> Bool {
        guard let url = tab.url, index(of: tab) != nil else { return false }
        let source: OpenSource
        do {
            let opener = opener
            source = try await Task.detached { try opener.read(url) }.value
        } catch {
            showProblem(Problems.open(error, tab.title))
            return false
        }
        if index(of: tab) != nil {
            await open(PendingOpen(source, replacing: tab), password: tab.password, certificate: tab.certificate)
        }
        return index(of: tab) == nil
    }
}
