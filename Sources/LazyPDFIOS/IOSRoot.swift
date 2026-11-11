#if os(iOS)
import SwiftUI
import LazyPDFApp
import LazyPDFUI

// The window of the iPhone and iPad app: AppWindow with the page viewer in the stage and the panels of SidePanelView, laid
// out for a phone or a tablet by its own width.

struct IOSRoot: View {
    @Bindable var shell: IOSShell
    @Environment(\.scenePhase) private var phase

    var body: some View {
        let vm = shell.vm
        let panels = shell.panels
        AppWindow(vm, commands: shell.commands, toolAction: { panels.action(for: $0) }, heldStage: { panels.stage }, readout: { tab in
            let viewer = shell.viewer(for: tab)
            return (viewer.pageLabel(tab.pageIndex), viewer.zoom)
        }, stage: { tab in
            PageViewerView(viewer: shell.viewer(for: tab))
        }, sidePane: { id, tab in
            SidePanelView(id: id, tab: tab, viewer: shell.viewer(for: tab), host: vm, folders: shell.folders)
        }, inspector: { id, tab in
            ToolHostView(id: id, tab: tab, viewer: shell.viewer(for: tab), panels: panels)
        })
        .sheet(item: $shell.sheet, onDismiss: shell.sheetClosed) { request in
            switch request.kind {
            case .open:
                OpenPicker { shell.finishPicking($0) }
            case .export(let file):
                ExportPicker(file: file) { shell.finishPicking($0) }
            case .share(let file):
                ShareSheet(files: [file])
            case .create:
                CreateSheet(host: vm) { shell.sheet = nil }
            case .batch:
                BatchSheet(host: vm, folders: shell.folders) { shell.sheet = nil }
            }
        }
        .environment(\.shortcutsInMenu, true)
        .onOpenURL { shell.receive($0) }
        .focusedSceneValue(\.viewerCommands, viewerCommands)
        .onChange(of: vm.documents.map(\.id)) { shell.dropClosedViewers() }
        .onChange(of: vm.activeDocument.map(ObjectIdentifier.init), initial: true) { shell.showActive() }
        .onChange(of: phase) { _, now in
            if now == .background { vm.flushRecovery() }
        }
        .task { await shell.openLaunchFixture() }
    }

    private var viewerCommands: ViewerCommandState? {
        let vm = shell.vm
        guard !vm.isBlocked else { return nil }
        let tab = vm.activeDocument
        let viewer = tab.map(shell.viewer(for:))
        return ViewerCommandState(actions: FileActions(vm: vm, commands: shell.commands), open: shell.commands.open,
                                  close: { if let tab { vm.requestClose(tab) } }, hasDocument: tab != nil,
                                  canUndo: vm.canUndo, canRedo: vm.canRedo, viewer: viewer,
                                  canGoBack: viewer?.canGoBack ?? false, canGoForward: viewer?.canGoForward ?? false)
    }
}
#endif
