import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/AppViewModel.Print.cs: Lazy Print gets the file when it is there, otherwise the window is
// asked to print the document itself.

extension AppViewModel {
    /// What a print control says: the name of the app it opens when that is Lazy Print.
    public var printLabel: String { sisters.lazyPrintInstalled ? L10n.t("Lazy Print") : L10n.t("Print") }

    public func print() {
        guard let tab = activeDocument else { return }
        if let security = tab.document.security, !security.openedAsOwner, !security.permissions.contains(.print) {
            showProblem(Problem(L10n.t("Printing is not allowed"), L10n.t("The owner of {0} did not allow it to be printed.", tab.title)))
            return
        }
        guard sisters.lazyPrintInstalled else {
            systemPrintRequested?(tab)
            return
        }
        let file: URL
        do {
            file = try writePrintCopy(tab)
        } catch {
            showProblem(Problem(L10n.t("Not printed"), L10n.t("A copy of {0} could not be made for printing. Check that the disk has room.", tab.title)))
            return
        }
        printCopyOwners = printCopyOwners.filter { $0.value.tab != nil }
        printCopyOwners[file.standardizedFileURL.path] = WeakTab(tab: tab)
        if sisters.tryPrint(file) {
            setStatus(L10n.t("Sent to Lazy Print."))
        } else {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            systemPrintRequested?(tab)
        }
    }

    /// Lazy Print could not be started with the copy of a document: the window prints that document itself.
    public func lazyPrintFailed(_ file: URL) {
        guard let tab = printCopyOwners[file.standardizedFileURL.path]?.tab, index(of: tab) != nil else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        systemPrintRequested?(tab)
    }

    // The file as it stands now, unsaved changes included, in a folder of its own so the name stays the document's.
    // Lazy Print may read it later, so it is not removed here; what is a day old goes at the next print.
    private func writePrintCopy(_ tab: DocumentTab) throws -> URL {
        let files = FileManager.default
        let yesterday = Date().addingTimeInterval(-86400)
        for old in (try? files.contentsOfDirectory(at: printDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let changed = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, changed < yesterday {
                try? files.removeItem(at: old)
            }
        }
        let folder = printDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = tab.title.lowercased().hasSuffix(".pdf") ? tab.title : tab.title + ".pdf"
        let file = folder.appendingPathComponent(name)
        try Data(tab.session.current).write(to: file)
        return file
    }
}

struct WeakTab {
    weak var tab: DocumentTab?
}
