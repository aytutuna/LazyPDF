import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Panels/Comments/CommentsSidePanel.Review.cs: answering the comment that is picked, and the
// summary file.

extension CommentsModel {
    /// Adds `text` as a reply to the picked comment. False when nothing was written, in which case the box keeps its text.
    @discardableResult
    public func reply(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tab, let host, let row = selectedRow, !words.isEmpty, !host.isDocumentBusy, !MarkWork.shared.running else { return false }
        let write = { [self] () -> Bool in
            guard self.tab === tab, !host.isDocumentBusy, !MarkWork.shared.running else { return false }
            return answer(tab, host, L10n.t("Reply")) {
                _ = try PdfComments.reply(tab.document, row.comment.annotation, words, author, PanelDates.now())
            }
        }
        if let warning = Self.caution(tab.document) {
            host.showNotice(L10n.t("Check before going on"), warning, NoticeAction(L10n.t("Go on anyway"), { _ = write() }))
            return false
        }
        return write()
    }

    /// Sets the review status of the picked comment.
    public func setStatus(_ status: ReviewStatus) {
        guard let tab, let host, let row = selectedRow, status != row.comment.status, !host.isDocumentBusy, !MarkWork.shared.running else { return }
        let write = { [self] () -> Bool in
            guard self.tab === tab, !host.isDocumentBusy, !MarkWork.shared.running else { return false }
            return answer(tab, host, L10n.t("Set status")) {
                _ = try PdfComments.setStatus(tab.document, row.comment.annotation, status, author, PanelDates.now())
            }
        }
        if let warning = Self.caution(tab.document) {
            host.showNotice(L10n.t("Check before going on"), warning, NoticeAction(L10n.t("Go on anyway"), { _ = write() }))
            return
        }
        _ = write()
    }

    /// The comments on show as plain text; nil, with the status line saying so, when there are none.
    public func summaryText() -> String? {
        guard let tab, let viewer, let host else { return nil }
        let comments = visible()
        if comments.isEmpty {
            host.setStatus(L10n.t("No comments to export."))
            return nil
        }
        return CommentSummary.text(tab.title, comments, { viewer.pageLabel($0) })
    }

    /// The name the summary is offered under, without an extension.
    public var summaryName: String {
        let title = tab?.title ?? ""
        return URL(fileURLWithPath: title).deletingPathExtension().lastPathComponent + " " + L10n.t("Comments")
    }

    public func summarySaved(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            host?.setStatus(L10n.t("Summary saved."))
        case .failure:
            host?.showProblem(Problem(L10n.t("Not saved"),
                                      L10n.t("{0} could not be written. Check that the disk has room and try again.", summaryName + ".txt")))
        }
    }

    // What to tell before a reply goes into a signed file; nil when the file is not signed.
    private static func caution(_ document: PdfDocument) -> String? {
        if !document.isSigned { return nil }
        return document.isCertified ? L10n.t("This file is certified, so changing it makes viewers report it as altered.")
            : L10n.t("This file is signed, so changing it breaks the signatures.")
    }

    private func answer(_ tab: DocumentTab, _ host: ToolHost, _ label: String, _ write: () throws -> Void) -> Bool {
        do {
            try write()
        } catch is ArgumentException {
            try? tab.session.discard()
            host.showProblem(Problem(L10n.t("This comment cannot be answered"),
                                     L10n.t("Its file stores it in a way that has no room for replies. Add a note next to it.")))
            return false
        } catch {
            try? tab.session.discard()
            host.showProblem(Problem(L10n.t("Change not kept"), L10n.t("The file would not read back with that change. Save a copy and try again.")))
            return false
        }
        do {
            return try tab.commit(label)
        } catch {
            try? tab.session.discard()
            host.showProblem(Problem(L10n.t("Change not kept"), L10n.t("The file would not read back with that change. Save a copy and try again.")))
            return false
        }
    }
}
