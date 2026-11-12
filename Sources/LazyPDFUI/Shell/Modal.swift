#if canImport(SwiftUI)
import Foundation

/// What the window shows in its one sheet. SwiftUI presents a single sheet at a time, so the password question, which stops
/// the window, comes before settings, and those before the tool and panel sheets of the phone layout.
enum Modal: String, Identifiable {
    case password, settings, certificates, about, tool, panel

    var id: String { rawValue }

    static func current(passwordAsked: Bool, local: Modal?, compact: Bool, toolOpen: Bool, panelOpen: Bool) -> Modal? {
        if passwordAsked { return .password }
        if let local { return local }
        if compact && toolOpen { return .tool }
        if compact && panelOpen { return .panel }
        return nil
    }
}
#endif
