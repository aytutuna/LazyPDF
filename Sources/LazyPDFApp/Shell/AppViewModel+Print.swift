import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/AppViewModel.Print.cs. Printing: Lazy Print gets the file when it is there, otherwise the
// window prints it with the system's dialog.

extension AppViewModel {
    public func print() {
        guard let tab = activeDocument else { return }
        if let security = tab.document.security, !security.openedAsOwner, !security.permissions.contains(.print) {
            showProblem(Problem(L10n.t("Printing is not allowed"), L10n.t("The owner of {0} did not allow it to be printed.", tab.title)))
            return
        }
        let file: URL
        do {
            file = try writePrintCopy(tab)
        } catch {
            showProblem(Problem(L10n.t("Not printed"), L10n.t("A copy of {0} could not be made for printing. Check that the disk has room.", tab.title)))
            return
        }
        if sisters.tryPrint(file) {
            setStatus(L10n.t("Sent to Lazy Print."))
        } else {
            systemPrintRequested?(tab)
        }
    }

    // The file as it stands now, unsaved changes included, in a folder of its own so the name stays the document's. Lazy
    // Print may read it later, so it is not removed here; what is a day old goes at the next print.
    private func writePrintCopy(_ tab: DocumentTab) throws -> URL {
        let files = FileManager.default
        let yesterday = Date().addingTimeInterval(-86400)
        let old = (try? files.contentsOfDirectory(at: printCopies, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in old where ((try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()) < yesterday {
            try? files.removeItem(at: folder)
        }
        let folder = printCopies.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = tab.title.lowercased().hasSuffix(".pdf") ? tab.title : tab.title + ".pdf"
        let file = folder.appendingPathComponent(name)
        try Data(tab.session.current).write(to: file)
        return file
    }
}
