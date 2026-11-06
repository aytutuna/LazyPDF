#if os(macOS)
import AppKit
import LazyPDFMac

NSApplication.shared.setActivationPolicy(.regular)
MacApp.main()
#endif
