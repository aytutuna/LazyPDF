#if os(iOS)
import SwiftUI
import LazyPDFKit
import LazyPDFApp
import LazyPDFUI

// The menu of the Mac for a hardware keyboard on the iPad, which shows these in the shortcut list and keeps them in a
// window narrower than the file buttons need. The state is nil while a job runs or a question is up, as the Windows
// shortcuts are off while a modal or a job is. Close and Find next are shortcuts of the window and the find bar.

struct ViewerCommandState {
    let actions: FileActions
    let open: () -> Void
    let hasDocument: Bool
    let canUndo: Bool
    let canRedo: Bool
    let viewer: ViewerModel?
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
        CommandGroup(after: .newItem) {
            Button(L10n.t("Open a file")) { state?.open() }
                .keyboardShortcut("o")
                .disabled(state == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button(L10n.t("Save")) { state?.actions.save() }
                .keyboardShortcut("s")
                .disabled(state?.hasDocument != true)
            Button(L10n.t("Save as…")) { state?.actions.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(state?.hasDocument != true)
        }
        CommandGroup(replacing: .printItem) {
            Button(L10n.t("Print")) { state?.actions.print() }
                .keyboardShortcut("p")
                .disabled(state?.hasDocument != true)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(L10n.t("Undo")) { state?.actions.undo() }
                .keyboardShortcut("z")
                .disabled(state?.canUndo != true)
            Button(L10n.t("Redo")) { state?.actions.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(state?.canRedo != true)
        }
        CommandGroup(after: .textEditing) {
            Button(L10n.t("Find")) { state?.viewer?.showFind() }
                .keyboardShortcut("f")
                .disabled(state?.viewer == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(L10n.t("Zoom in")) { state?.viewer?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(state?.viewer == nil)
            Button(L10n.t("Zoom out")) { state?.viewer?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(state?.viewer == nil)
            Button(L10n.t("Actual size")) { state?.viewer?.actualSize() }
                .keyboardShortcut("0")
                .disabled(state?.viewer == nil)
            Button(L10n.t("Go to page")) { state?.viewer?.showGoToPage() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(state?.viewer == nil)
            Button(L10n.t("Back")) { state?.viewer?.goBack() }
                .keyboardShortcut("[")
                .disabled(state?.canGoBack != true)
            Button(L10n.t("Forward")) { state?.viewer?.goForward() }
                .keyboardShortcut("]")
                .disabled(state?.canGoForward != true)
        }
    }
}
#endif
