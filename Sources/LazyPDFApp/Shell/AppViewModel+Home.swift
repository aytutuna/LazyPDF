import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/AppViewModel.Home.cs. The Home tab: the files opened last, the tiles for the jobs people
// come for, and what Lazy PDF offers after a crash.

/// A file in the recent list, with the words the Home tab shows for it.
public struct RecentItem: Equatable {
    public let url: URL
    public let name: String
    public let folder: String
    public let opened: String
    public let exists: Bool
}

/// A job on the Home tab. `reason` says why it cannot be started, nil when it can.
public struct HomeTile: Equatable {
    public let id: String
    public let title: String
    /// An SF Symbol name.
    public let symbol: String
    public let description: String
    public let available: Bool
    public let reason: String?

    /// The description, and why the tile cannot be started when it cannot, for the tooltip and screen readers.
    public var helpText: String {
        reason.map { L10n.t("{0} Not available: {1}", description, $0) } ?? description
    }
}

extension AppViewModel {
    public static let openTile = "open"
    public static let createTile = "create"
    public static let scanTile = "scan"
    public static let batchTile = "batch"

    /// The tools behind the tiles that are tools: tile id, tool id.
    private static let toolTiles: [(tile: String, tool: String)] = [
        ("combine", "combine"), ("compress", "optimize"), ("protect", "protect"), ("sign", "fillsign"),
        ("form", "forms"), ("edit", "editcontent"), ("export", "export"),
    ]

    public var tiles: [HomeTile] {
        _ = version
        let hasDocument = lastDocument != nil
        let needFile = L10n.t("Open a file first")
        func forTool(_ id: String, _ title: String, _ symbol: String, _ description: String) -> HomeTile {
            HomeTile(id: id, title: title, symbol: symbol, description: description, available: hasDocument, reason: hasDocument ? nil : needFile)
        }

        // Lazy Scan is a separate app: its tile is there only when it is.
        let scan = sisters.lazyScanInstalled
            ? [HomeTile(id: Self.scanTile, title: L10n.t("Scan"), symbol: "scanner", description: L10n.t("Scan paper into a PDF with Lazy Scan."),
                        available: true, reason: nil)]
            : []

        return [
            HomeTile(id: Self.openTile, title: L10n.t("Open"), symbol: "folder", description: L10n.t("Open a PDF, a picture or a text file."),
                     available: true, reason: nil),
            HomeTile(id: Self.createTile, title: L10n.t("Create"), symbol: "doc.badge.plus",
                     description: L10n.t("Make a PDF from blank pages, pictures, text or the clipboard."), available: true, reason: nil),
            forTool("combine", L10n.t("Combine"), "square.on.square", L10n.t("Join files into a new one, or split this one.")),
            forTool("compress", L10n.t("Make smaller"), "arrow.down.right.and.arrow.up.left", L10n.t("Make the file smaller.")),
            forTool("protect", L10n.t("Protect"), "lock", L10n.t("Set a password and decide what others may do.")),
            forTool("sign", L10n.t("Sign"), "signature", L10n.t("Sign the file with your name.")),
            forTool("form", L10n.t("Fill a form"), "list.bullet.rectangle", L10n.t("Fill in the fields of a form.")),
            forTool("edit", L10n.t("Edit"), "pencil", L10n.t("Change the words and pictures on a page.")),
        ] + scan + [
            forTool("export", L10n.t("Export"), "square.and.arrow.up", L10n.t("Save as Word, Excel, PowerPoint, HTML, text or pictures.")),
            HomeTile(id: Self.batchTile, title: L10n.t("Batch"), symbol: "square.stack.3d.up",
                     description: L10n.t("Do the same to every file in a folder."), available: true, reason: nil),
        ]
    }

    /// Starts the job behind a tile: a tool opens on the document last in use, Scan starts Lazy Scan. Open is the window's,
    /// since it needs the file panel. A tile that cannot be started says why in the status line.
    public func startTile(_ id: String) {
        if id == Self.scanTile {
            if sisters.lazyScanInstalled { sisters.openLazyScan() }
            return
        }
        guard let tool = Self.toolTiles.first(where: { $0.tile == id })?.tool else { return }
        guard let last = lastDocument, index(of: last) != nil else {
            if let tile = tiles.first(where: { $0.id == id }) { setStatus(tile.helpText) }
            return
        }
        activeTab = last
        activeToolId = tool
        notifyAll()
    }

    /// The PNG of the first page of a recent file, for its card; nil when the file is gone or cannot be drawn.
    public func thumbnail(of item: RecentItem) async -> [UInt8]? {
        guard item.exists else { return nil }
        let access = bookmarks.access(item.url)
        defer { access?.stop() }
        let thumbnails = thumbnails
        return await Task.detached { await thumbnails.get(item.url) }.value
    }

    /// Takes a file out of the recent list.
    public func forgetRecent(_ url: URL) {
        recentFiles.remove(url)
        recent = buildRecent()
        notifyAll()
    }

    public func clearRecent() {
        recentFiles.clear()
        recent = buildRecent()
        notifyAll()
    }

    func buildRecent() -> [RecentItem] {
        recentFiles.load().map { file in
            let url = recentFiles.locate(file)
            return RecentItem(url: url, name: url.lastPathComponent, folder: Self.folderName(url), opened: Self.when(file.opened),
                              exists: FileManager.default.fileExists(atPath: url.path))
        }
    }

    private static func folderName(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let leaf = folder.lastPathComponent
        return leaf.isEmpty ? folder.path : leaf
    }

    private static func when(_ opened: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: opened), to: calendar.startOfDay(for: Date())).day ?? 0
        if days <= 0 { return L10n.t("Today") }
        if days == 1 { return L10n.t("Yesterday") }
        let formatter = DateFormatter()
        if days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: opened)
    }

    /// Looks in the recovery folder: anything there is what a crash left, because a document closed on purpose removes its
    /// copy.
    public func checkRecovery() {
        let found = recovery.abandoned()
        recoveryOffer = found.isEmpty ? nil : found
        notifyAll()
    }

    /// Opens what `recoveryOffer` lists, as documents with unsaved changes.
    public func restore() async {
        let offer = recoveryOffer
        recoveryOffer = nil
        notifyAll()
        for entry in offer ?? [] {
            let bytes: [UInt8]
            do {
                let file = entry.pdf
                bytes = try await Task.detached { [UInt8](try Data(contentsOf: file)) }.value
            } catch {
                showProblem(Problems.open(error, entry.meta.title))
                continue
            }
            // A file that is open already comes back as a copy that needs a name, not as a second tab on the file.
            // The path alone is not enough in a sandbox; a bookmark that no longer leads anywhere leaves the copy to be named.
            var url = original(entry.meta)
            if let found = url, tab(of: found) != nil { url = nil }
            let access = url.flatMap { bookmarks.access($0) }
            let stamp = entry.meta.originalWrite.map { DiskStamp(write: $0, length: entry.meta.originalLength) }
            let source = OpenSource(bytes: bytes, url: url, title: entry.meta.title, made: false, stamp: url == nil ? nil : stamp)
            await open(PendingOpen(source, recovery: entry.id, access: access), password: nil, certificate: nil)
        }
    }

    private func original(_ meta: RecoveryMeta) -> URL? {
        if let bookmark = meta.bookmark { return bookmarks.resolve(bookmark)?.url }
        return meta.originalPath.map { URL(fileURLWithPath: $0) }
    }

    public func discardRecovery() {
        for entry in recoveryOffer ?? [] { recovery.delete(entry.id) }
        recoveryOffer = nil
        notifyAll()
    }
}
