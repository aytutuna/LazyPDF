#if os(iOS)
import SwiftUI
import LazyPDFKit
import LazyPDFApp
import LazyPDFUI

// The menu of the Mac for a hardware keyboard on the iPad, which shows these in the shortcut list. Open, Save, Print, Undo,
// Redo and Close are shortcuts of the window itself, and Find next is the find bar's, so they are not repeated here.

struct ViewerCommandState {
    let viewer: ViewerModel
    let canGoBack: Bool
    let canGoForward: Bool
}

private struct ViewerCommandsKey: FocusedValueKey {
    typealias Value = ViewerCommandState
}

extension FocusedValues {
    var viewerCommands: ViewerCommandState? {
        get { self[ViewerCommandsKey.self] }
        set { self[ViewerCommandsKey.self] = newValue }
    }
}

struct ViewerCommands: Commands {
    @FocusedValue(\.viewerCommands) private var state

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(L10n.t("Find")) { state?.viewer.showFind() }
                .keyboardShortcut("f")
                .disabled(state == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(L10n.t("Zoom in")) { state?.viewer.zoomIn() }
                .keyboardShortcut("+")
                .disabled(state == nil)
            Button(L10n.t("Zoom out")) { state?.viewer.zoomOut() }
                .keyboardShortcut("-")
                .disabled(state == nil)
            Button(L10n.t("Actual size")) { state?.viewer.actualSize() }
                .keyboardShortcut("0")
                .disabled(state == nil)
            Button(L10n.t("Go to page")) { state?.viewer.showGoToPage() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(state == nil)
            Button(L10n.t("Back")) { state?.viewer.goBack() }
                .keyboardShortcut("[")
                .disabled(state?.canGoBack != true)
            Button(L10n.t("Forward")) { state?.viewer.goForward() }
                .keyboardShortcut("]")
                .disabled(state?.canGoForward != true)
        }
    }
}
#endif
