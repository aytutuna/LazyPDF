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

    /// For the edits that copy pages in from another file: the change is made off the main actor on a copy of the file as it
    /// stands, and only its update goes into the tab it started on, wherever the person has moved to meanwhile. The tab's own
    /// document is not touched until then, so the window can read it while the job runs and Cancel drops the copy.
    @discardableResult
    public static func applyAsync(_ tab: DocumentTab, _ host: ToolHost, busy: String, label: String,
                                  _ change: @escaping @Sendable (PdfDocument) throws -> Void, status: String) async -> Bool {
        let copy = TabCopy(tab, host)
        var update: [UInt8]?
        do {
            try await host.runBusy(busy) { token in
                update = try await ToolDocuments.run(token) {
                    try token.throwIfCancelled()
                    let document = try copy.open()
                    try change(document)
                    try token.throwIfCancelled()
                    return try PdfEditSession.update(of: document)
                }
            }
        } catch {
            host.showProblem(refusal)
            return false
        }
        guard let update, !tab.isDisposed else { return false }
        do {
            if try !tab.session.commit(label, update: update, over: copy.file.count) { return false }
        } catch {
            host.showProblem(refusal)
            return false
        }
        tab.reload()
        host.setStatus(status)
        return true
    }

    static var refusal: Problem {
        Problem(L10n.t("Pages not changed"), L10n.t("The file did not take that change. Pick other pages and try again."))
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
        host.showProblem(refusal)
    }

    /// The pages as a PDF of their own, made off the main actor. Nil when the file does not allow copying, when it was cancelled
    /// or when it failed, with `failed` shown.
    public static func copyOut(_ tab: DocumentTab, _ host: ToolHost, _ pages: [Int], busy: String, failed: Problem) async -> [UInt8]? {
        if CopyRules.refused(tab.document, host) { return nil }
        var bytes: [UInt8]?
        var skipped = 0
        let copy = TabCopy(tab, host)
        do {
            try await host.runBusy(busy) { token in
                (bytes, skipped) = try await ToolDocuments.run(token) {
                    try token.throwIfCancelled()
                    let extract = try PageAssembly.extract(copy.open(), pages)
                    let made = try extract.saveRewrite()
                    try token.throwIfCancelled()
                    return (made, extract.skippedAttachments)
                }
            }
        } catch {
            host.showProblem(failed)
            return nil
        }
        noteSkippedAttachments(host, skipped)
        return bytes
    }

    public static func noteSkippedAttachments(_ host: ToolHost, _ skipped: Int) {
        if skipped == 0 { return }
        host.showNotice(L10n.t("Attachments left out"),
                        L10n.plural(skipped, one: "{0} attachment could not be read and was left out.", other: "{0} attachments could not be read and were left out."), nil)
    }
}
