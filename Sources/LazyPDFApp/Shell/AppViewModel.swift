import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/AppViewModel.cs. Printing, the tools and the panels are not here; the active tool and the
// side panel stay plain ids for the piece that adds them.

/// A button the info bar offers beside its message.
public struct NoticeAction {
    public let text: String
    public let run: @MainActor () -> Void

    public init(_ text: String, _ run: @escaping @MainActor () -> Void) {
        self.text = text
        self.run = run
    }
}

/// What the info bar says: a title, the sentence under it and, if it helps, a button.
public struct InfoMessage {
    public let title: String
    public let text: String
    public let isError: Bool
    public let action: NoticeAction?
}

/// Stands for the C# CancellationToken of a busy job: the job looks at it between steps.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func throwIfCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// The state of the window: the tabs, the tool and side panel in use, the info bar and the busy bar. Documents, recovery
/// and the home tiles are in the extensions.
///
/// Whatever a view reads through a computed property depends on `version`, which every change of state bumps, as the
/// window of the Windows app reads everything back when it is told "changed".
@MainActor
@Observable
public final class AppViewModel {
    @ObservationIgnored let renderers: () -> DocumentRenderer
    @ObservationIgnored let opener: DocumentOpener
    @ObservationIgnored let sisters: SisterApps
    @ObservationIgnored let certificates: CertificateKeys
    @ObservationIgnored let recovery: RecoveryStore
    @ObservationIgnored let recentFiles: RecentFiles
    @ObservationIgnored let bookmarks: Bookmarks
    @ObservationIgnored let settings: URL
    @ObservationIgnored let printDirectory: URL

    /// How the tabs write their files; the iPhone and iPad shell sets a coordinated writer.
    @ObservationIgnored public var fileWriter: FileWriter = PlainFileWriter()

    private(set) var version = 0

    public internal(set) var strip: [any StripTab] = [HomeTab.shared]
    public internal(set) var activeTab: any StripTab = HomeTab.shared
    var lastDocument: DocumentTab?
    public internal(set) var activeToolId: String?
    public private(set) var sidePanelId: String
    @ObservationIgnored private var lastSidePanelId: String
    public private(set) var appearance: AppAppearance
    public internal(set) var message: InfoMessage?
    private var status = ""
    private var busy: CancelToken?
    private var busyLabel = ""

    var pending: [PendingOpen] = []
    @ObservationIgnored var opening = Set<String>()
    @ObservationIgnored var warnedAboutDisk: [ObjectIdentifier: DiskStamp?] = [:]
    @ObservationIgnored var exiting = false
    public internal(set) var closeQuestion: DocumentTab?
    public internal(set) var recent: [RecentItem] = []
    public internal(set) var recoveryOffer: [RecoveryEntry]?

    /// Called once everything that had unsaved changes has been dealt with.
    @ObservationIgnored public var exitRequested: (() -> Void)?

    /// Called when Lazy Print did not take the document: the window prints it itself.
    @ObservationIgnored public var systemPrintRequested: ((DocumentTab) -> Void)?

    public init(renderers: @escaping () -> DocumentRenderer, codec: ImageCodec, fonts: FontSource, sisters: SisterApps,
                certificates: CertificateKeys, bookmarks: Bookmarks, folders: AppFolders) {
        self.renderers = renderers
        opener = DocumentOpener(codec, fonts)
        self.sisters = sisters
        self.certificates = certificates
        settings = folders.settings
        printDirectory = folders.printCopies
        recovery = RecoveryStore(directory: folders.recovery)
        self.bookmarks = bookmarks
        recentFiles = RecentFiles(directory: folders.settings, bookmarks: bookmarks)
        let preferences = AppPreferencesStore.load(folders.settings)
        sidePanelId = preferences.sidePanel
        lastSidePanelId = preferences.sidePanel.isEmpty ? "pages" : preferences.sidePanel
        appearance = preferences.appearance
        recent = buildRecent()
    }

    /// The Home tab first, then the open documents in the order shown.
    public var documents: [DocumentTab] { strip.compactMap { $0 as? DocumentTab } }

    public var activeDocument: DocumentTab? { activeTab as? DocumentTab }

    public var isHome: Bool { activeTab is HomeTab }

    public func select(_ tab: any StripTab) {
        if activeTab === tab || index(of: tab) == nil { return }
        activeTab = tab
        dropAction()
        if let document = tab as? DocumentTab { lastDocument = document }
        notifyAll()
        checkDisk()
    }

    func index(of tab: any StripTab) -> Int? {
        strip.firstIndex { $0 === tab }
    }

    /// The status sentence in full, for screen readers.
    public var statusFull: String { status }

    public var statusShort: String { StatusLine.short(status) }

    public var isBusy: Bool { busy != nil }

    public var busyText: String { busyLabel }

    /// Opens the tool whose panel the inspector shows, or closes it when it is the open one.
    public func selectTool(_ id: String?) {
        if let id, ToolCatalog.find(id) == nil { return }
        activeToolId = id == activeToolId ? nil : id
        dropAction()
        notifyAll()
    }

    /// Opens the side panel `id`, or closes the rail's panel when that one is open already.
    public func setSidePanel(_ id: String) {
        sidePanelId = id == sidePanelId ? "" : id
        if !sidePanelId.isEmpty { lastSidePanelId = sidePanelId }
        let panel = sidePanelId
        AppPreferencesStore.update(settings) { $0.sidePanel = panel }
        notifyAll()
    }

    /// Collapses the rail's panel, or opens the one that was open last.
    public func toggleSidePanel() {
        setSidePanel(sidePanelId.isEmpty ? lastSidePanelId : sidePanelId)
    }

    public func setAppearance(_ value: AppAppearance) {
        appearance = value
        AppPreferencesStore.update(settings) { $0.appearance = value }
        notifyAll()
    }

    // A button on the info bar acts on the tab and tool it was made for, so it goes when they do.
    func dropAction() {
        if message?.action != nil { message = nil }
    }

    public func showNotice(_ title: String, _ text: String, _ action: NoticeAction? = nil) {
        message = InfoMessage(title: title, text: text, isError: false, action: action)
        notifyAll()
    }

    public func showProblem(_ problem: Problem) {
        message = InfoMessage(title: problem.title, text: problem.text, isError: true, action: nil)
        notifyAll()
    }

    public func dismissMessage() {
        message = nil
        notifyAll()
    }

    public func setStatus(_ sentence: String) {
        status = sentence
        notifyAll()
    }

    /// Runs `work` with the busy bar showing `text` and a Cancel that ends it. A refusal by the file's own permissions is
    /// explained here; any other error is the tool's to explain.
    public func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws {
        let token = CancelToken()
        busy = token
        busyLabel = text
        notifyAll()
        defer {
            // A job that started over this one must keep the bar.
            if busy === token {
                busy = nil
                busyLabel = ""
            }
            notifyAll()
        }
        do {
            try await work(token)
        } catch is CancellationError {
            setStatus(L10n.t("Cancelled."))
        } catch is PdfPermissionException {
            showProblem(Problems.restricted())
        }
    }

    public func setBusyText(_ text: String) {
        if busy == nil { return }
        busyLabel = text
        notifyAll()
    }

    public func cancelBusy() {
        busy?.cancel()
    }

    func notifyAll() {
        version &+= 1
    }
}
