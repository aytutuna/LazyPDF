import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Optimize/OutputWriter.cs: where the result of a tool that rewrites the whole file goes,
// a new tab or over the file the tab was read from.

public enum OutputWriter {
    /// True, with the info bar saying why, when the file on disk is not the one the tab was read from and replacing it would
    /// drop the other version.
    @MainActor
    public static func refuses(_ host: ToolHost, _ tab: DocumentTab, replace: Bool) -> Bool {
        guard replace, let url = tab.url, tab.changedOnDisk, FileManager.default.fileExists(atPath: url.path) else { return false }
        host.showProblem(Problem(L10n.t("File changed"), L10n.t("{0} was changed by another program. Pick New file, or open that version first.", tab.title)))
        return true
    }

    /// False when the result was not delivered; the info bar says why and the open document is as it was. `revision` is the
    /// one the bytes were made from.
    @MainActor
    public static func deliver(_ host: ToolHost, _ tab: DocumentTab, revision: Int, _ bytes: [UInt8], replace: Bool, newTitle: String) async -> Bool {
        if tab.revision != revision {
            host.showProblem(Problem(L10n.t("File changed"), L10n.t("{0} changed while this ran. Run it again.", tab.title)))
            return false
        }
        guard replace, let url = tab.url else {
            await host.openNew(bytes, title: newTitle, password: tab.password, certificate: tab.certificate)
            return true
        }
        if refuses(host, tab, replace: replace) { return false }
        do {
            try await write(url, bytes, tab, host)
        } catch {
            host.showProblem(Problems.save(error, tab.title))
            return false
        }
        if await host.tryReload(tab) { return true }
        host.showProblem(Problem(L10n.t("File written, not shown"), L10n.t("{0} was saved but could not be read again. Open it from disk.", tab.title)))
        return false
    }

    // The bytes are checked by reading them back the way the tab was opened, off the main actor.
    @MainActor
    private static func write(_ url: URL, _ bytes: [UInt8], _ tab: DocumentTab, _ host: ToolHost) async throws {
        let password = tab.password
        let source = tab.document
        let writer = host.fileWriter
        #if canImport(Security)
        let held = tab.certificate.flatMap { host.verifyCertificate($0) }.flatMap { PdfCertificate($0) }
        #endif
        try await Task.detached {
            try writer.write(to: url) { target in
                #if canImport(Security)
                if let held {
                    try PdfFileSaver.save(target.path, bytes, certificate: held, source: source)
                    return
                }
                #endif
                try PdfFileSaver.save(target.path, bytes, password: password, source: source)
            }
        }.value
    }
}
