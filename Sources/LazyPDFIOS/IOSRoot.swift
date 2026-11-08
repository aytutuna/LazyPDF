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
            StageView(viewer: shell.viewer(for: tab), tab: tab)
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
        .onOpenURL { shell.receive($0) }
        .focusedSceneValue(\.viewerCommands, viewerCommands)
        .onChange(of: vm.documents.map(\.id)) { shell.dropClosedViewers() }
        .onChange(of: phase) { _, now in
            if now == .background { vm.flushRecovery() }
        }
        .task { await shell.openLaunchFixture() }
    }

    private var viewerCommands: ViewerCommandState? {
        guard let tab = shell.vm.activeDocument else { return nil }
        let viewer = shell.viewer(for: tab)
        return ViewerCommandState(viewer: viewer, canGoBack: viewer.canGoBack, canGoForward: viewer.canGoForward)
    }
}

private struct StageView: View {
    let viewer: ViewerModel
    let tab: DocumentTab

    var body: some View {
        PageViewerView(viewer: viewer)
            .onAppear { viewer.show(tab) }
            .onDisappear { viewer.show(nil) }
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
