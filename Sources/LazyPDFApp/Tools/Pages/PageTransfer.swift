import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Pages/PageTransfer.cs: pages going from one tab to another, or out into a tab of their own.
// The caller gates a paste into the tab it works on; a copy into another tab gates itself.

@MainActor
public enum PageTransfer {
    /// The change that puts the pages of `pdf` into a document at `at`, or at its end when nil. The end is read from the document
    /// being changed, which importPages needs right, since it traps on an index past the end.
    nonisolated static func importer(_ pdf: [UInt8], at: Int?) -> @Sendable (PdfDocument) throws -> Void {
        { document in
            let source = try PdfDocument.open(pdf)
            try OrganizeModel.importAll(document, source, min(at ?? document.pages.count, document.pages.count))
        }
    }

    @discardableResult
    public static func paste(_ target: DocumentTab, _ host: ToolHost, _ pdf: [UInt8], count: Int, at: Int?) async -> Bool {
        await PageJobs.applyAsync(target, host, busy: L10n.t("Adding pages"), label: L10n.t("Paste pages"), importer(pdf, at: at),
                                  status: L10n.plural(count, one: "{0} page pasted", other: "{0} pages pasted"))
    }

    /// Copies the dragged or chosen pages to the end of `to`, which is not the tab they are in.
    public static func copy(_ from: PageDragPayload, to: DocumentTab, host: ToolHost) async {
        await ChangeGate.runAsync(to, host, L10n.t("Copy pages"), file: to.title) { await transfer(from, to, host) }
    }

    private static func transfer(_ from: PageDragPayload, _ to: DocumentTab, _ host: ToolHost) async {
        guard let tab = from.tab, tab !== to else { return }
        let open = host.openDocuments
        if tab.isDisposed || to.isDisposed || !open.contains(where: { $0 === tab }) || !open.contains(where: { $0 === to }) {
            refuse(host, L10n.t("One of the two files is not open any more."))
            return
        }
        if changed(from, tab) {
            refuse(host, L10n.t("The pages changed since they were picked. Pick them again."))
            return
        }
        if MarkWork.shared.running {
            refuse(host, L10n.t("Wait for the running job to finish, then try again."))
            return
        }
        if to.drawnRevision != to.revision {
            refuse(host, L10n.t("{0} is still loading. Try again in a moment.", to.title))
            return
        }
        let failed = Problem(L10n.t("Pages not copied"), L10n.t("The pages could not be copied. Try fewer pages."))
        guard let bytes = await PageJobs.copyOut(tab, host, from.pages, busy: L10n.t("Copying pages"), failed: failed, files: false),
              await paste(to, host, bytes, count: from.pages.count, at: nil) else { return }
        host.setStatus(L10n.plural(from.pages.count, one: "Copied {0} page to {1}. Undo it in {1}.",
                                   other: "Copied {0} pages to {1}. Undo it in {1}.", to.title))
        CopyRules.noteUnprotected(tab.document, host)
    }

    /// Makes a new tab of the pages. The Extract buttons pass `files` to take the attachments along, a drag or a menu does not.
    public static func toNewTab(_ from: PageDragPayload, _ host: ToolHost, files: Bool) async {
        guard let tab = from.tab, !tab.isDisposed else {
            refuse(host, L10n.t("One of the two files is not open any more."))
            return
        }
        if changed(from, tab) {
            refuse(host, L10n.t("The pages changed since they were picked. Pick them again."))
            return
        }
        let failed = Problem(L10n.t("Pages not extracted"), L10n.t("The pages could not be copied into a new file. Try fewer pages."))
        guard let bytes = await PageJobs.copyOut(tab, host, from.pages, busy: L10n.t("Extracting pages"), failed: failed, files: files) else { return }
        let stem = (tab.title as NSString).deletingPathExtension
        await host.openNew(bytes, title: L10n.t("{0} extract.pdf", stem), password: nil, certificate: nil)
        host.setStatus(L10n.plural(from.pages.count, one: "{0} page extracted", other: "{0} pages extracted"))
        CopyRules.noteUnprotected(tab.document, host)
    }

    private static func changed(_ from: PageDragPayload, _ tab: DocumentTab) -> Bool {
        tab.revision != from.revision || from.pages.contains { $0 < 0 || $0 >= tab.pageCount }
    }

    private static func refuse(_ host: ToolHost, _ text: String) {
        host.showProblem(Problem(L10n.t("Pages not copied"), text))
    }
}
