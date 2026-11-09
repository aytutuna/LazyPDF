import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Comment/MarkWork.cs: what the comment panels share, whether a long change to the file is
// running, and the commit that tolerates a file that will not take it.

@MainActor
@Observable
public final class MarkWork {
    public static let shared = MarkWork()

    /// True while import, flatten or attach changes the document off the main actor; nothing else may touch it meanwhile.
    /// The window reads it for `isBlocked` and `isDocumentBusy`, and the Comments side panel before it answers.
    public internal(set) var running = false

    init() {}

    /// What to tell before marks are added to a signed file; nil when the file is not signed.
    public static func caution(_ document: PdfDocument) -> String? {
        if !document.isSigned { return nil }
        return document.isCertified ? L10n.t("This file is certified, so changing it makes viewers report it as altered.")
            : L10n.t("This file is signed, so changing it breaks the signatures.")
    }

    /// Holds a change to a signed file back until the person goes on anyway; true when it was held back.
    public static func cautioned(_ tab: DocumentTab, _ host: ToolHost, again: @escaping @MainActor () -> Void) -> Bool {
        guard let warning = caution(tab.document) else { return false }
        host.showNotice(L10n.t("Check before going on"), warning, NoticeAction(L10n.t("Go on anyway"), again))
        return true
    }

    /// Commits the change; a file that does not read back with it is put back as it was, with a problem shown.
    public static func commit(_ tab: DocumentTab, _ host: ToolHost, _ label: String) throws -> Bool {
        do {
            return try tab.commit(label)
        } catch where error is PdfReadException || error is InvalidOperationException || error is ArgumentException {
            try? tab.session.discard()
            host.showProblem(Problem(L10n.t("Change not kept"), L10n.t("The file would not read back with that change. Save a copy and try again.")))
            return false
        }
    }

    /// Changes the open document off the main actor with the busy bar up and the rest of the panel and the side panel held
    /// back. Anything but a clean finish (a stop, a failure, another tab) puts the file back as it was and gives nil; a
    /// failure is thrown once the file is back. The file is put back only after the job has really ended, since Cancel
    /// returns before it does.
    public func change<T>(_ tab: DocumentTab, _ host: ToolHost, _ text: String, isCurrent: @MainActor () -> Bool,
                          _ job: @escaping @Sendable (PdfDocument, CancelToken) throws -> T) async throws -> T? {
        let ended = JobEnd()
        let document = tab.document
        var result: T?
        var failure: Error?
        running = true
        do {
            try await host.runBusy(text) { token in
                result = try await ToolDocuments.run(token) {
                    defer { ended.set() }
                    try token.throwIfCancelled()
                    return try job(document, token)
                }
            }
        } catch {
            failure = error
        }
        while !ended.isSet { try? await Task.sleep(nanoseconds: 10_000_000) }
        running = false
        if let failure {
            try? tab.session.discard()
            throw failure
        }
        if result == nil || !isCurrent() {
            try? tab.session.discard()
            return nil
        }
        return result
    }
}

private final class JobEnd: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    func set() {
        lock.lock()
        ended = true
        lock.unlock()
    }
}
