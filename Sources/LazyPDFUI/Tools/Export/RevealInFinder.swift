#if canImport(SwiftUI)
import Foundation
#if os(macOS)
import AppKit
#endif

// What the Show in folder button of an export does where the platform has a Finder; iOS has none to show a file in.

enum RevealInFinder {
    #if os(macOS)
    static let action: ((URL) -> Void)? = { url in
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    #else
    static let action: ((URL) -> Void)? = nil
    #endif
}
#endif
