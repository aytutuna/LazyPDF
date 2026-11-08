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
        let panels = shell.panels
        AppWindow(vm, commands: shell.commands, toolAction: { panels.action(for: $0) }, stage: { _ in
            PageViewerView(viewer: viewer)
        }, sidePane: { id, tab in
            SidePanelView(id: id, tab: tab, viewer: viewer, host: vm, folders: shell.folders)
        }, inspector: { id, tab in
            ToolHostView(id: id, tab: tab, viewer: viewer, panels: panels)
        })
        .frame(minWidth: 640, minHeight: 480)
        .environment(\.shortcutsInMenu, true)
        .onChange(of: ObjectIdentifier(vm.activeTab), initial: true) { viewer.show(vm.activeDocument) }
        .onChange(of: vm.closeQuestion == nil) { shell.closeQuestionChanged() }
        .background(WindowHook { shell.attach($0) })
    }
}
#endif
