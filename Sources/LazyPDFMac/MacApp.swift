#if os(macOS)
import SwiftUI
import LazyPDFApp
import LazyPDFUI

/// The Mac app. The Xcode project's app target (mac/project.yml) and Sources/LazyPDF only start it.
public struct MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let shell = MacShell.shared

    public init() {
        // The tab strip is the app's own.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    public var body: some Scene {
        // One window, as on Windows: a second would show every question twice.
        Window("Lazy PDF", id: "main") {
            MacWindow(shell: shell)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { MacMenus(shell: shell) }
    }
}

struct MacWindow: View {
    let shell: MacShell

    var body: some View {
        let vm = shell.vm
        let viewer = shell.viewer
        AppWindow(vm, commands: shell.commands, stage: { _ in
            PageViewerView(viewer: viewer)
        }, sidePane: { id, tab in
            SidePanelView(id: id, tab: tab, viewer: viewer, host: vm, folders: shell.folders)
        }, inspector: { id, _ in
            ToolSummary(id: id)
        })
        .frame(minWidth: 640, minHeight: 480)
        .environment(\.shortcutsInMenu, true)
        .onChange(of: ObjectIdentifier(vm.activeTab), initial: true) { viewer.show(vm.activeDocument) }
        .onChange(of: vm.closeQuestion == nil) { shell.closeQuestionChanged() }
        .background(WindowHook { shell.attach($0) })
    }
}

// TODO: the panels of the tools; for now the inspector says what the chosen tool is for.
private struct ToolSummary: View {
    let id: String

    var body: some View {
        Text(ToolCatalog.find(id)?.summary ?? "")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}
#endif
