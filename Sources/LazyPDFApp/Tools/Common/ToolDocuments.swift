import Foundation
import LazyPDFKit

// Follows OptimizeJob.Open and NeedsOwner of windows/LazyPDF.App/Tools/Optimize/OptimizeJob.cs: a tool that works off the main
// actor opens its own copy of the file's bytes, the way the tab opened them.

public enum ToolDocuments {
    /// `certificate` is the identity a file for recipients was opened with, from `ToolHost.verifyCertificate`.
    public static func open(_ file: [UInt8], password: String?, certificate: X509Certificate?) throws -> PdfDocument {
        #if canImport(Security)
        if let certificate, let held = PdfCertificate(certificate) { return try PdfDocument.open(file, certificate: held) }
        #endif
        return try PdfDocument.open(file, password: password)
    }

    /// True when the file restricts what may be done to it and was not opened with the owner's rights, so a rewrite is
    /// refused.
    public static func needsOwner(_ document: PdfDocument) -> Bool {
        guard let security = document.security else { return false }
        return !security.openedAsOwner && security.permissions != .all
    }
}

extension ToolDocuments {
    /// Runs `work` off the main actor and gives its result, or throws CancellationError as soon as `token` is cancelled,
    /// without waiting for the job to notice: `WaitAsync(token)` of the Windows tools. The job's task is cancelled at the same
    /// time, which the engine's `Task.checkCancellation` calls see; the job must still look at the token between steps.
    public static func run<T>(_ token: CancelToken, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let job = Task.detached {
                do {
                    once.resume(returning: try work())
                } catch {
                    once.resume(throwing: error)
                }
            }
            Task.detached {
                while !token.isCancelled && !once.isDone { try? await Task.sleep(nanoseconds: 50_000_000) }
                if token.isCancelled { job.cancel() }
                once.resume(throwing: CancellationError())
            }
        }
    }
}

private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation == nil
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let held = continuation
        continuation = nil
        return held
    }
}
