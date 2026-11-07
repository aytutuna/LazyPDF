#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import LazyPDFApp
import LazyPDFKit

// Follows the dialogs of windows/LazyPDF.App/MainWindow.Files.cs. A url from a panel carries the sandbox grant for as long as
// the app runs, so nothing has to be started or stopped for it.

@MainActor
enum MacFilePanels {
    /// PDFs, pictures and text files: what FileKinds says the app takes.
    static var openTypes: [UTType] {
        (["pdf"] + FileKinds.pictureExtensions + FileKinds.textExtensions).compactMap { UTType(filenameExtension: $0) }
    }

    static func openPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = L10n.t("Open")
        panel.allowedContentTypes = openTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return panel
    }

    static func open() -> [URL] {
        let panel = openPanel()
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// `title` is "Save as" or "Save compact". The name offered is the document's, as on Windows.
    static func savePanel(_ title: String, name: String, folder: URL?) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = pdfName(name)
        panel.directoryURL = folder
        return panel
    }

    static func save(_ title: String, name: String, folder: URL?) -> URL? {
        let panel = savePanel(title, name: name, folder: folder)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pdfName(_ name: String) -> String {
        (name as NSString).deletingPathExtension + ".pdf"
    }
}
#endif
