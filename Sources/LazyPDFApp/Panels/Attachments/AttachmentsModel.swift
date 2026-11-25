import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Attachments/AttachmentsSidePanel.xaml.cs.

/// One line of the list.
public struct AttachmentRow: Identifiable {
    public let id: Int
    public let item: PdfAttachment
    public let pageText: String

    public var name: String { item.fileName.isEmpty ? item.name : item.fileName }

    public var details: String {
        [item.size.map(Self.size), pageText, item.description ?? ""].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var summary: String { details.isEmpty ? name : name + ", " + details }

    private static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return L10n.t("{0} bytes", bytes) }
        if bytes < 1024 * 1024 { return L10n.t("{0} KB", (Double(bytes) / 1024 * 10).rounded() / 10) }
        return L10n.t("{0} MB", (Double(bytes) / 1_048_576 * 10).rounded() / 10)
    }
}

/// The files carried inside the PDF: open one, or save it. A file that could run as a program can only be saved.
@MainActor
@Observable
public final class AttachmentsModel: ToolPanelModel {
    public private(set) var rows: [AttachmentRow] = []
    public var selected: Int?
    public private(set) var note: String?

    /// Hands the copy made for opening to the system; false when nothing could open it. The view sets it, since opening is
    /// a different call on the Mac and on the iPhone.
    @ObservationIgnored public var launch: ((URL) -> Bool)?

    @ObservationIgnored private let openedFolder: URL
    @ObservationIgnored private var tab: DocumentTab?
    @ObservationIgnored private var host: ToolHost?
    @ObservationIgnored private var watch: ObservationWatch?

    public init(openedFolder: URL) {
        self.openedFolder = openedFolder
    }

    public var action: ToolAction? { nil }

    /// Removes the copies made to open attachments, which hold the file decrypted. One a program still has open stays.
    public static func deleteOpenedCopies(in folder: URL) {
        guard let copies = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for copy in copies { try? FileManager.default.removeItem(at: copy) }
    }

    public func attach(_ tab: DocumentTab, _ viewer: DocumentViewer, _ host: ToolHost) {
        self.tab = tab
        self.host = host
        watch = ObservationWatch(track: { _ = tab.revision }, changed: { [weak self] in self?.build() })
        build()
    }

    public func detach() {
        watch?.stop()
        watch = nil
        rows = []
        selected = nil
        tab = nil
        host = nil
    }

    public var selectedRow: AttachmentRow? {
        rows.first { $0.id == selected }
    }

    /// The name the file is saved under, and its bytes; nil when it cannot be read, which the note then says.
    public func fileToSave() -> (name: String, bytes: [UInt8])? {
        guard let row = selectedRow, let bytes = read(row) else { return nil }
        return (AttachmentFiles.safeName(row.name), bytes)
    }

    public func saved(_ result: Result<URL, Error>) {
        switch result {
        case .success: note = nil
        case .failure: note = L10n.t("The attachment could not be saved. Check the folder and try again.")
        }
    }

    public func open() {
        guard let row = selectedRow else { return }
        let name = AttachmentFiles.safeName(row.name)
        if AttachmentFiles.couldRun(name) {
            note = L10n.t("This file could run as a program. Save it instead.")
            return
        }
        guard let tab, let host else { return }
        let revision = tab.revision
        host.showNotice(L10n.t("Open this attachment?"), L10n.t("{0} came inside this PDF. Open it only if you trust where the PDF came from.", row.name),
                        NoticeAction(L10n.t("Open"), { [weak self] in self?.openCopy(row, name, tab, revision) }))
    }

    private func openCopy(_ row: AttachmentRow, _ name: String, _ tab: DocumentTab, _ revision: Int) {
        guard self.tab === tab else { return }
        // A commit or undo may have renumbered the objects, so the row could now be another file.
        if tab.revision != revision {
            note = L10n.t("The file changed meanwhile. Try again.")
            return
        }
        guard let bytes = read(row) else { return }
        do {
            let folder = openedFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name.isEmpty ? "attachment" : name)
            try Data(bytes).write(to: file)
            if launch?(file) == true { note = nil } else { note = L10n.t("This attachment could not be opened.") }
        } catch {
            note = L10n.t("This attachment could not be opened.")
        }
    }

    private func read(_ row: AttachmentRow) -> [UInt8]? {
        guard let tab else { return nil }
        do {
            return try PdfAttachments.extract(tab.document, row.item)
        } catch {
            note = L10n.t("This attachment could not be read.")
            return nil
        }
    }

    private func build() {
        guard let tab else { return }
        rows = PdfAttachments.list(tab.document).enumerated().map { i, attachment in
            AttachmentRow(id: i, item: attachment, pageText: attachment.pageIndex.map { L10n.t("Page {0}", $0 + 1) } ?? "")
        }
        if selected.map({ $0 >= rows.count }) == true { selected = nil }
        note = nil
    }
}
