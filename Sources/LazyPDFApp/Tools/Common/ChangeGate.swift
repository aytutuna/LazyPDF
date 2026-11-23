import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Stamps/ChangeGate.cs.

/// What stands before a change that is not the tool's pinned action: the file's permissions, its signatures, and a failure
/// that must not end the app.
@MainActor
public enum ChangeGate {
    /// Why the file may not be changed; nil when it may.
    public static func refusal(_ document: PdfDocument, file: String? = nil) -> Problem? {
        if let security = document.security, !security.openedAsOwner, !security.permissions.contains(.modify) {
            return Problems.restricted(file)
        }
        return nil
    }

    /// Runs `work` unless the file forbids it; a signed file asks first, and `work` runs when the answer is yes. `name` is
    /// what the failure message calls the job. A change to a file that is not the one in view passes its `file` name, so the
    /// notice, which is shown over the active tab, says which file it is about.
    public static func run(_ tab: DocumentTab, _ host: ToolHost, _ name: String, file: String? = nil,
                           _ work: @escaping @MainActor () throws -> Void) {
        if clear(tab, host, file, then: { guarded(host, name, work, file) }) { guarded(host, name, work, file) }
    }

    /// The same for work that waits on something.
    public static func runAsync(_ tab: DocumentTab, _ host: ToolHost, _ name: String, file: String? = nil,
                                _ work: @escaping @MainActor () async throws -> Void) async {
        if clear(tab, host, file, then: { Task { await guardedAsync(host, name, work, file) } }) { await guardedAsync(host, name, work, file) }
    }

    // True when the change may go ahead now; otherwise the info bar says why, or offers `then` after a warning.
    private static func clear(_ tab: DocumentTab, _ host: ToolHost, _ file: String?, then: @escaping @MainActor () -> Void) -> Bool {
        if let problem = refusal(tab.document, file: file) {
            host.showProblem(problem)
            return false
        }
        guard tab.document.isSigned else { return true }
        let certified = tab.document.isCertified
        let warning = switch (certified, file) {
        case (true, nil): L10n.t("This file is certified, so changing it makes viewers report it as altered.")
        case (false, nil): L10n.t("This file is signed, so changing it breaks the signatures.")
        case (true, let file?): L10n.t("{0} is certified, so changing it makes viewers report it as altered.", file)
        case (false, let file?): L10n.t("{0} is signed, so changing it breaks the signatures.", file)
        }
        host.showNotice(L10n.t("Check before going on"), warning, NoticeAction(L10n.t("Go on anyway"), then))
        return false
    }

    /// Runs `work` for a tool's pinned button: what fails is explained on the info bar and the app goes on.
    public static func guarded(_ host: ToolHost, _ name: String, _ work: @MainActor () throws -> Void, _ file: String? = nil) {
        do {
            try work()
        } catch {
            report(error, host, name, file)
        }
    }

    public static func guardedAsync(_ host: ToolHost, _ name: String, _ work: @MainActor () async throws -> Void, _ file: String? = nil) async {
        do {
            try await work()
        } catch {
            report(error, host, name, file)
        }
    }

    private static func report(_ error: Error, _ host: ToolHost, _ name: String, _ file: String?) {
        if error is PdfPermissionException {
            host.showProblem(Problems.restricted(file))
        } else if error is PdfReadException {
            host.showProblem(Problem(L10n.t("Something went wrong"),
                                     L10n.t("{0} could not be finished because the file could not be read back. If part of it was done, Undo takes it back.", name)))
        } else if Problems.isFileSystem(error) {
            host.showProblem(Problem(L10n.t("Something went wrong"),
                                     L10n.t("{0} could not be finished. Check that the disk has room and that no other program has the file open.", name)))
        } else {
            host.showProblem(Problem(L10n.t("Something went wrong"),
                                     L10n.t("{0} could not be finished. If part of it was done, Undo takes it back.", name)))
        }
    }
}
