#if os(iOS)
import UIKit
import LazyPDFApp

// The iPhone asks the system whether Lazy Scan is there (LSApplicationQueriesSchemes in Info.plist lists lazyscan and
// lazyprint). A file cannot be handed to another app by path, so printing never goes to Lazy Print from here: the window
// prints through the system, and the share sheet hands a file over.

public struct IOSSisterApps: SisterApps {
    private static let scan = URL(string: "lazyscan:")!

    public init() {}

    public var lazyScanInstalled: Bool {
        MainActor.assumeIsolated { UIApplication.shared.canOpenURL(Self.scan) }
    }

    public var lazyPrintInstalled: Bool { false }

    public func openLazyScan() {
        MainActor.assumeIsolated { UIApplication.shared.open(Self.scan) }
    }

    public func tryPrint(_ file: URL) -> Bool {
        false
    }
}
#endif
