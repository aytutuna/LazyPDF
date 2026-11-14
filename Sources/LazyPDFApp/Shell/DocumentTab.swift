import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Documents/DocumentTab.cs.

/// One open document: the edit session, where it was read from, whether it has unsaved changes and the renderer that
/// draws it. Tools change `document` and call `commit`; the tab loads the renderer again, keeps the recovery copy
/// current and tells the window through `changed`.
@MainActor
@Observable
public final class DocumentTab: StripTab {
    public let id = UUID()
    public let session: PdfEditSession
    public let renderer: DocumentRenderer

    /// The password the file was opened with; nil when it needed none, or was opened with a certificate.
    public let password: String?

    /// The certificate the file was opened with; nil when it was opened any other way.
    public let certificate: CertificateChoice?

    private let recovery: RecoveryStore?
    private let bookmarks: Bookmarks?
    private let writer: FileWriter
    private var access: FileAccess?
    private var locationBookmark: Data?
    private var location: URL?
    private let name: String
    private var unsaved: Bool
    private var disk: DiskStamp?
    private var diskHash: Int?

    /// Bumped by every change of state the derived properties show.
    private var version = 0

    /// False when the system cannot draw the file (it can still be edited and saved).
    public private(set) var canDraw: Bool

    /// The tab was closed: its marks and fields have no document to go to.
    @ObservationIgnored public private(set) var isDisposed = false

    /// Counts every change to the file's bytes (commit, undo, redo, save compact), so a viewer knows when to draw again.
    public private(set) var revision = 0

    /// Counts the times the renderer was loaded for the latest `revision`: a view that draws from the renderer follows this,
    /// since the load of a big file finishes after the revision changed.
    public private(set) var drawn = 0

    /// The `revision` the renderer holds; it trails `revision` while a big file loads.
    @ObservationIgnored public private(set) var drawnRevision = 0

    @ObservationIgnored private var loading: Task<Void, Never>?

    /// The page the viewer shows, 0-based, kept here so each tab comes back as it was left.
    public var pageIndex = 0

    /// The viewer's zoom, 1 for 100 %; 0 while the zoom follows `fit` or the viewer has not chosen one.
    public var zoom = 0.0

    /// How the viewer's zoom follows the window; none while a zoom of its own is set.
    public var fit = FitMode.none

    /// Redaction marks drawn but not yet applied; they live in the Redact panel and are lost with the tab.
    public var pendingMarks = 0

    /// Measurements listed but not yet added to the page; they live in the Measure panel and are lost with the tab.
    public var pendingMeasurements = 0

    /// A corrected word typed in the OCR panel that a signed file would not take without asking.
    public var pendingWords = 0

    /// Figure descriptions typed in the Accessibility panel and not written to the file.
    public var pendingDescriptions = 0

    public var hasUnappliedWork: Bool { pendingMarks > 0 || pendingMeasurements > 0 || pendingWords > 0 || pendingDescriptions > 0 }

    /// Called when the file's bytes changed.
    @ObservationIgnored public var changed: (() -> Void)?

    /// - Parameters:
    ///   - url: Where the file lives; nil for a document made from pictures or text, which has to be saved as a new file.
    ///   - unsaved: The state differs from the file on disk although the session has no history: a document restored
    ///     after a crash, or one that was just made.
    ///   - known: What the file looked like when its bytes were read; what it looks like now when not given.
    ///   - loaded: What `renderer.load` gave, when the caller loaded it already, off the main actor; the tab loads it when
    ///     not given.
    public init(session: PdfEditSession, renderer: DocumentRenderer, url: URL?, title: String, password: String? = nil,
                recovery: RecoveryStore? = nil, unsaved: Bool = false, known: DiskStamp? = nil, diskHash: Int? = nil,
                certificate: CertificateChoice? = nil, loaded: Bool? = nil, bookmarks: Bookmarks? = nil, access: FileAccess? = nil,
                writer: FileWriter = PlainFileWriter(), readOnly: Bool = false) {
        self.session = session
        self.renderer = renderer
        self.location = url
        self.name = title
        self.password = password
        self.recovery = recovery
        self.bookmarks = bookmarks
        self.writer = writer
        self.access = access
        self.readOnly = readOnly
        self.locationBookmark = url.flatMap { bookmarks?.make($0) }
        self.unsaved = unsaved
        self.certificate = certificate
        let stamp = known ?? DiskStamp.of(url)
        self.disk = stamp
        self.diskHash = diskHash
        self.canDraw = loaded ?? renderer.load(session, password)
        if unsaved {
            recovery?.write(id, session.current, Self.meta(title: url?.lastPathComponent ?? title, url: url, stamp: stamp, bookmark: locationBookmark))
        }
    }

    /// The document at the current state; see `PdfEditSession.document`.
    public var document: PdfDocument { session.document }

    public var pageCount: Int { document.pages.count }

    public var url: URL? {
        _ = version
        return location
    }

    /// The file cannot be written to; the tab has a file of its own once it is saved under another name.
    public internal(set) var readOnly: Bool

    public var title: String {
        _ = version
        return location?.lastPathComponent ?? name
    }

    public var automationName: String { isDirty ? L10n.t("{0}, unsaved changes", title) : title }

    public var symbol: String { "doc" }

    public var isDirty: Bool {
        _ = version
        return unsaved || session.isDirty
    }

    public var canClose: Bool { true }

    /// Commits what a tool changed in `document` as one undoable step. False when nothing changed.
    @discardableResult
    public func commit(_ label: String, mergeWithPrevious: Bool = false) throws -> Bool {
        if try !session.commit(label, mergeWithPrevious: mergeWithPrevious) { return false }
        refresh()
        return true
    }

    /// Takes up steps the session committed by itself, as a signature does: loads the renderer again and tells the window.
    public func reload() {
        refresh()
    }

    @discardableResult
    public func undo() throws -> Bool {
        if try !session.undo() { return false }
        refresh()
        return true
    }

    @discardableResult
    public func redo() throws -> Bool {
        if try !session.redo() { return false }
        refresh()
        return true
    }

    public func save() throws {
        guard let location else { throw InvalidOperationException("The document has no file yet.") }
        try writer.write(to: location) { try session.save($0.path) }
        saved()
    }

    public func saveAs(_ url: URL) throws {
        try writer.write(to: url) { try session.save($0.path) }
        move(to: url)
        saved()
    }

    /// Writes the file without its history to `url` and goes on from that file.
    public func saveCompact(_ url: URL) throws {
        try writer.write(to: url) { try session.saveCompact($0.path) }
        move(to: url)
        saved(rewritten: true)
    }

    /// The file on disk is not the one that was read or saved: another program changed or removed it.
    public var changedOnDisk: Bool {
        location != nil && onDisk != disk
    }

    /// The file as it is now; nil when it is gone or the tab has no file.
    public var onDisk: DiskStamp? { DiskStamp.of(location) }

    /// The file has the length and the bytes that were read, so only its time moved, as a sync tool does.
    public func isOnlyTouched(_ found: DiskStamp) -> Bool {
        guard let diskHash, let location, found.length == disk?.length else { return false }
#if canImport(Darwin)
        let data = try? CoordinatedFileReader.read(location)
#else
        let data = try? Data(contentsOf: location)
#endif
        return data.flatMap { DocumentOpener.digest($0) } == diskHash
    }

    /// Takes the file as it is now for the one that was read.
    public func acceptDiskState() {
        disk = onDisk
    }

    /// For a tool whose engine call committed on the session itself: draws the new state and tells the window.
    public func refresh() {
        let background = renderer.loadsInBackground && !session.document.isEncrypted
        if !background { canDraw = renderer.load(session, password) }
        revision += 1
        version += 1
        writeRecovery()
        changed?()
        if background { startLoad() } else { drawnRevision = revision; drawn += 1 }
    }

    /// Returns once the renderer draws the current bytes. A job that pairs the renderer with `session.current` waits here first.
    public func whenDrawn() async {
        await loading?.value
    }

    // Loads follow one another, and one that a newer edit or the closing of the tab has outdated says nothing.
    private func startLoad() {
        let revision = revision
        let previous = loading
        loading = Task { [weak self] in
            await previous?.value
            guard let self, !self.isDisposed, revision == self.revision else { return }
            let drew = await self.renderer.loadAsync(self.session, self.password)
            guard revision == self.revision else { return }
            if self.isDisposed {
                self.renderer.close()
                return
            }
            self.canDraw = drew
            self.drawnRevision = revision
            self.drawn += 1
        }
    }

    // The bytes of a save are the ones already shown, so only the state of the tab changes, unless the save rewrote the file.
    private func saved(rewritten: Bool = false) {
        unsaved = false
        diskHash = DocumentOpener.digest(session.current)
        acceptDiskState()
        recovery?.delete(id)
        if rewritten {
            refresh()
        } else {
            version += 1
        }
    }

    private func writeRecovery() {
        guard let recovery else { return }
        if !isDirty {
            recovery.delete(id)
            return
        }
        recovery.write(id, session.current, Self.meta(title: title, url: location, stamp: disk, bookmark: locationBookmark))
    }

    private func move(to url: URL) {
        location = url
        readOnly = false
        locationBookmark = bookmarks?.make(url)
    }

    private nonisolated static func meta(title: String, url: URL?, stamp: DiskStamp?, bookmark: Data?) -> RecoveryMeta {
        RecoveryMeta(title: title, originalPath: url?.path, saved: Date(), originalWrite: stamp?.write,
                     originalLength: stamp?.length ?? 0, processId: Int(ProcessInfo.processInfo.processIdentifier),
                     started: ProcessCheck.launched, bookmark: bookmark)
    }

    /// Takes over the file grant of the tab this one replaces, so a reload does not stop it.
    func adoptAccess(from old: DocumentTab) {
        access = old.access
        old.access = nil
    }

    /// Keeps the grant for the file the tab was just saved to and ends the one for the file it came from.
    public func take(_ access: FileAccess?) {
        self.access?.stop()
        self.access = access
    }

    /// Lets go of the renderer and removes the recovery copy: closing on purpose is not a crash.
    public func dispose() {
        isDisposed = true
        renderer.close()
        recovery?.delete(id)
        access?.stop()
        access = nil
    }
}
