import Foundation

/// A started security-scoped access, ended once by `stop` or, failing that, when the object goes.
public final class SecurityScopedAccess: FileAccess {
    private let url: URL
    private let end: (URL) -> Void
    private let lock = NSLock()
    private var active = true

    /// For access started already; `stop` runs when it ends.
    public init(_ url: URL, stop: @escaping (URL) -> Void) {
        self.url = url
        end = stop
    }

    public func stop() {
        lock.lock()
        let was = active
        active = false
        lock.unlock()
        if was { end(url) }
    }

    deinit {
        stop()
    }
}

#if canImport(Darwin)
extension SecurityScopedAccess {
    /// Nil when the system refused access.
    public static func start(_ url: URL) -> SecurityScopedAccess? {
        url.startAccessingSecurityScopedResource() ? SecurityScopedAccess(url) { $0.stopAccessingSecurityScopedResource() } : nil
    }
}
#endif
