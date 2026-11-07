#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#endif

// The Windows window leaves Z and Y to a text box that has the keyboard (MainWindow.xaml.cs, Window_PreviewKeyDown). On the
// Mac the shortcut of a button is handled before the field editor sees the key, so the button asks first. UIKit offers the
// key to the text input before the window's commands, so the iPad needs no check.
enum EditFocus {
    #if os(macOS)
    static func text(in window: NSWindow?) -> NSText? {
        guard let text = window?.firstResponder as? NSText, text.isEditable else { return nil }
        return text
    }
    #endif

    /// Undoes or redoes in the text being typed in and says true; false when no text has the keyboard.
    @MainActor
    static func undoInText(redo: Bool) -> Bool {
        #if os(macOS)
        guard let text = text(in: NSApp.keyWindow) else { return false }
        if redo { text.undoManager?.redo() } else { text.undoManager?.undo() }
        return true
        #else
        return false
        #endif
    }
}
#endif
