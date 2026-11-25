#if os(macOS)
import AppKit
import LazyPDFApp

// Follows windows/LazyPDF.App/Services/SisterApps.cs. The apps are found by bundle id. A file is handed to Lazy Print
// through NSWorkspace, which passes the sandbox grant with it; a path in a lazyprint: address would reach a sandboxed
// app unreadable.
//
// tryPrint answers before LaunchServices has launched anything, so a launch that then fails is reported through
// `printFailed`, which the window answers by printing the file itself, as it does when Lazy Print is missing.

final class MacSisterApps: SisterApps {
    private let scanId: String
    private let printId: String

    /// Called on the main actor with the file when Lazy Print could not be opened with it.
    var printFailed: (@MainActor (URL) -> Void)?

    init(scanId: String = "com.lazyscan.lazyscan", printId: String = "com.lazyprint.lazyprint") {
        self.scanId = scanId
        self.printId = printId
    }

    var lazyScanInstalled: Bool { location(scanId) != nil }

    var lazyPrintInstalled: Bool { location(printId) != nil }

    func openLazyScan(_ failed: @escaping @MainActor () -> Void) {
        guard let app = location(scanId) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            Task { @MainActor in failed() }
        }
    }

    func tryPrint(_ file: URL) -> Bool {
        guard let app = location(printId) else { return false }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.printFailed?(file) }
        }
        return true
    }

    private func location(_ bundleId: String) -> URL? {
        // A copy left in the Trash is still known to LaunchServices.
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).flatMap { $0.path.contains("/.Trash/") ? nil : $0 }
    }
}
#endif
