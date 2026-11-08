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
        AppWindow(vm, commands: shell.commands, stage: { tab in
            PageViewerView(viewer: shell.viewer(for: tab))
        }, sidePane: { id, tab in
            SidePanelView(id: id, tab: tab, viewer: shell.viewer(for: tab), host: vm, folders: shell.folders)
        }, inspector: { id, _ in
            ToolSummary(id: id)
        })
        .sheet(item: $shell.sheet, onDismiss: shell.sheetClosed) { request in
            switch request.kind {
            case .open:
                OpenPicker { shell.finishPicking($0) }
            case .export(let file):
                ExportPicker(file: file) { shell.finishPicking($0) }
            case .share(let file):
                ShareSheet(files: [file])
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
        guard !vm.isBusy, vm.closeQuestion == nil, vm.recoveryOffer == nil, vm.passwordRequest == nil else { return nil }
        let tab = vm.activeDocument
        let viewer = tab.map(shell.viewer(for:))
        return ViewerCommandState(actions: FileActions(vm: vm, commands: shell.commands), open: shell.commands.open,
                                  hasDocument: tab != nil, canUndo: vm.canUndo, canRedo: vm.canRedo, viewer: viewer,
                                  canGoBack: viewer?.canGoBack ?? false, canGoForward: viewer?.canGoForward ?? false)
    }
}

// TODO: the tools' own panels come with the tools; for now the inspector says what the tool will do.
private struct ToolSummary: View {
    let id: String

    var body: some View {
        if let tool = ToolCatalog.find(id) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tool.title).font(.headline)
                Text(tool.summary).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
#endif
