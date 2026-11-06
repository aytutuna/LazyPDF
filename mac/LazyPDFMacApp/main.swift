import AppKit
import LazyPDFMac

// The Mac app of the App Store build. Everything it does is in the package (Sources/LazyPDFMac); this target only starts
// it, as Sources/LazyPDF does for `swift build`.
NSApplication.shared.setActivationPolicy(.regular)
MacApp.main()
