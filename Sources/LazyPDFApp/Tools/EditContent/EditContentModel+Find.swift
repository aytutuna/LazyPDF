import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/EditContentPanel.Find.cs: replace all, the words of the whole file, on every
// page at once.

extension EditContentModel {
    public var canReplaceAll: Bool { !findText.isEmpty && !isReplacing }

    public func replaceAll() async {
        guard let edits, let host, let tab, !isReplacing, !findText.isEmpty else { return }
        finishPending()
        if !allowed({ [weak self] in Task { await self?.replaceAll() } }) { return }
        let start = tab.session.current
        let find = findText, replacement = replaceText
        let options = TextSearchOptions(matchCase: matchCase, wholeWord: wholeWord)
        var made: ReplacedCopy?
        isReplacing = true
        defer { isReplacing = false }
        do {
            try await host.runBusy(L10n.t("Replacing text")) { token in
                let copy = try await edits.replaceAll(start, find, replacement, options, token)
                if !token.isCancelled { made = copy }
            }
            guard let made else { return }
            let outcome = try edits.adopt(made)
            ownRevision = tab.revision
            if outcome.done { host.setStatus(L10n.t("Text replaced.")) }
            if self.tab !== tab { return }
            surface?.clear()
            showOutcome(outcome)
        } catch is CancellationError {
            return
        } catch {
            host.showProblem(Problem(L10n.t("Text not replaced"), L10n.t("The file could not be changed. Try again or open it again.")))
        }
    }
}
