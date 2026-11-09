import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Pages/PageJobs.cs: what the Pages panel and the organize view both do with a tab: one change
// to the document as one undo step, and pages copied out.

@MainActor
public enum PageJobs {
    @discardableResult
    public static func apply(_ tab: DocumentTab, _ host: ToolHost, _ label: String, _ change: (PdfDocument) throws -> Void,
                             _ status: String) -> Bool {
        do {
            try change(tab.document)
        } catch {
            refuse(host, tab)
            return false
        }
        return commit(tab, host, label, status)
    }

    /// For the edits that copy pages in from another file: the work runs off the main actor and the result goes to the tab it
    /// started on, wherever the person has moved to meanwhile. The change is made in the tab's own document, which nothing else
    /// may touch meanwhile, so Cancel is answered when the change ends and then drops it.
    @discardableResult
    public static func applyAsync(_ tab: DocumentTab, _ host: ToolHost, busy: String, label: String,
                                  _ change: @escaping @Sendable (PdfDocument) throws -> Void, status: String) async -> Bool {
        var done = false
        do {
            try await host.runBusy(busy) { token in
                let document = tab.document
                try token.throwIfCancelled()
                try await Task.detached { try change(document) }.value
                done = !token.isCancelled
            }
        } catch {
            refuse(host, tab)
            return false
        }
        if done { return commit(tab, host, label, status) }
        try? tab.session.discard()
        return false
    }

    private static func commit(_ tab: DocumentTab, _ host: ToolHost, _ label: String, _ status: String) -> Bool {
        do {
            if try !tab.commit(label) { return false }
        } catch {
            refuse(host, tab)
            return false
        }
        host.setStatus(status)
        return true
    }

    /// What was changed in memory is dropped, so a half-done edit cannot be committed later with another one.
    public static func refuse(_ host: ToolHost, _ tab: DocumentTab) {
        try? tab.session.discard()
        host.showProblem(Problem(L10n.t("Pages not changed"), L10n.t("The file did not take that change. Pick other pages and try again.")))
    }

    /// The pages as a PDF of their own, made off the main actor. Nil when the file does not allow copying, when it was cancelled
    /// or when it failed, with `failed` shown.
    public static func copyOut(_ tab: DocumentTab, _ host: ToolHost, _ pages: [Int], busy: String, failed: Problem) async -> [UInt8]? {
        if CopyRules.refused(tab.document, host) { return nil }
        var bytes: [UInt8]?
        let copy = TabCopy(tab, host)
        do {
            try await host.runBusy(busy) { token in
                bytes = try await ToolDocuments.run(token) {
                    try token.throwIfCancelled()
                    let made = try PageAssembly.extract(copy.open(), pages).saveRewrite()
                    try token.throwIfCancelled()
                    return made
                }
            }
        } catch {
            host.showProblem(failed)
            return nil
        }
        return bytes
    }
}
