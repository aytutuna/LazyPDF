#if os(macOS)
import AppKit
import LazyPDFApp

// Follows windows/LazyPDF.App/Services/SisterApps.cs. The apps are found by bundle id. A file is handed to Lazy Print
// through NSWorkspace, which passes the sandbox grant with it; a path in a lazyprint: address would reach a sandboxed
// app unreadable.

final class MacSisterApps: SisterApps {
    private let scanId: String
    private let printId: String

    init(scanId: String = "com.lazyscan.lazyscan", printId: String = "com.lazyprint.lazyprint") {
        self.scanId = scanId
        self.printId = printId
    }

    var lazyScanInstalled: Bool { location(scanId) != nil }

    func openLazyScan() {
        guard let app = location(scanId) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func tryPrint(_ file: URL) -> Bool {
        guard let app = location(printId) else { return false }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private func location(_ bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }
}
#endif
