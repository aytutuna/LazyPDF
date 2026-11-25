#if os(macOS)
import SwiftUI
import LazyPDFApp
import LazyPDFUI

/// The Mac app. The Xcode project's app target (mac/project.yml) and Sources/LazyPDF only start it.
public struct MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {
        // The tab strip is the app's own.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    public var body: some Scene {
        // The value is the window's id. It is nil for the window the system opens, and whatever a restored window was given.
        WindowGroup("Lazy PDF", id: "doc", for: UUID.self) { $value in
            MacWindowRoot(value: value)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { MacMenus(hub: WindowHub.shared) }
    }
}

struct FocusedShellKey: FocusedValueKey {
    typealias Value = MacShell
}

extension FocusedValues {
    var macShell: MacShell? {
        get { self[FocusedShellKey.self] }
        set { self[FocusedShellKey.self] = newValue }
    }
}

/// Asks the hub for the shell of its window when it appears. A window the hub has no use for closes at once.
struct MacWindowRoot: View {
    let value: UUID?
    @State private var shell: MacShell?
    @State private var asked = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let shell {
                MacWindow(shell: shell)
            } else {
                Color.clear
            }
        }
        .onAppear {
            WindowHub.shared.captureOpenWindow { openWindow(value: $0) }
            if asked { return }
            asked = true
            if let claimed = WindowHub.shared.claim(value) { shell = claimed } else { dismiss() }
        }
        .onDisappear {
            if let shell { WindowHub.shared.windowGone(shell) }
        }
    }
}

struct WindowState: Equatable {
    let title: String
    let url: URL?
    let dirty: Bool

    @MainActor init(_ tab: DocumentTab?) {
        title = tab?.title ?? "Lazy PDF"
        url = tab?.url
        dirty = tab?.isDirty ?? false
    }
}

struct MacWindow: View {
    let shell: MacShell

    var body: some View {
        let vm = shell.vm
        let viewer = shell.viewer
        let panels = shell.panels
        AppWindow(vm, commands: shell.commands, toolAction: { panels.action(for: $0) }, heldStage: { panels.stage }, readout: { (viewer.pageLabel($0.pageIndex), viewer.zoom) }, stage: { _ in
            PageViewerView(viewer: viewer)
        }, sidePane: { id, tab in
            SidePanelView(id: id, tab: tab, viewer: viewer, host: vm, folders: shell.folders)
        }, inspector: { id, tab in
            ToolHostView(id: id, tab: tab, viewer: viewer, panels: panels)
        })
        .frame(minWidth: 640, minHeight: 480)
        .environment(\.shortcutsInMenu, true)
        .onChange(of: ObjectIdentifier(vm.activeTab), initial: true) {
            // The tool panel may have shown it first, and showing again would clear the marks it drew.
            if viewer.tab !== vm.activeDocument { viewer.show(vm.activeDocument) }
        }
        .onChange(of: WindowState(vm.activeDocument), initial: true) { _, state in shell.update(state) }
        .onChange(of: vm.closeQuestion == nil) { shell.closeQuestionChanged() }
        .onChange(of: vm.isBlocked || vm.sheetOpen) { shell.becameIdle() }
        .onChange(of: vm.message == nil) { shell.becameIdle() }
        .focusedSceneValue(\.macShell, shell)
        .background(WindowHook { shell.attach($0) })
    }
}
#endif
