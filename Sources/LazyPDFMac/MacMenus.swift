#if os(macOS)
import SwiftUI
import LazyPDFApp
import LazyPDFKit
import LazyPDFUI

// The menu bar. The shortcuts are those of the Windows window, moved to the Mac's keys; the tool strip and the viewer's bar
// keep their own buttons.

struct MacMenus: Commands {
    let shell: MacShell

    private var vm: AppViewModel { shell.vm }
    private var viewer: ViewerModel { shell.viewer }
    private var actions: FileActions { FileActions(vm: vm, commands: shell.commands) }
    private var free: Bool { !vm.isBlocked }
    private var usable: Bool { vm.activeDocument != nil && free }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.t("Open")) { shell.commands.open() }
                .keyboardShortcut("o")
                .disabled(!free)
            Menu(L10n.t("Open Recent")) {
                ForEach(vm.recent, id: \.url) { item in
                    Button(item.name) { Task { await vm.openRecent(item) } }
                }
                Divider()
                Button(L10n.t("Clear menu")) { vm.clearRecent() }
                    .disabled(vm.recent.isEmpty)
            }
            .disabled(!free)
        }
        CommandGroup(replacing: .saveItem) {
            Button(L10n.t("Close tab")) {
                if let tab = vm.activeDocument { vm.requestClose(tab) }
            }
            .keyboardShortcut("w")
            .disabled(!usable)
            Divider()
            Button(L10n.t("Save"), action: actions.save)
                .keyboardShortcut("s")
                .disabled(!usable)
            Button(L10n.t("Save as…"), action: actions.saveAs)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!usable)
            Button(L10n.t("Save compact…"), action: actions.saveCompact)
                .disabled(!usable)
        }
        CommandGroup(replacing: .printItem) {
            Button(L10n.t("Print"), action: actions.print)
                .keyboardShortcut("p")
                .disabled(!usable)
        }
        CommandGroup(replacing: .undoRedo) {
            // Always on: the keys belong to the text being typed in first (FileActions.undo), and the document's own step
            // does nothing when there is none.
            Button(actions.undoHelp, action: actions.undo)
                .keyboardShortcut("z")
            Button(actions.redoHelp, action: actions.redo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(L10n.t("Find")) { viewer.showFind() }
                .keyboardShortcut("f")
                .disabled(!usable)
            Button(L10n.t("Next match")) { viewer.search.next() }
                .keyboardShortcut("g")
                .disabled(viewer.search.hits.isEmpty || !free)
            Button(L10n.t("Previous match")) { viewer.search.previous() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(viewer.search.hits.isEmpty || !free)
        }
        CommandGroup(after: .toolbar) {
            viewItems
        }
        CommandMenu(L10n.t("Go")) {
            goItems
        }
        CommandMenu(L10n.t("Tools")) {
            ForEach(ToolGroup.allCases, id: \.self) { group in
                Menu(ToolCatalog.groupTitle(group)) {
                    ForEach(ToolCatalog.tools.filter { $0.group == group }, id: \.id) { tool in
                        Toggle(tool.title, isOn: Binding(get: { vm.activeToolId == tool.id }, set: { _ in vm.selectTool(tool.id) }))
                    }
                }
                .disabled(!usable)
            }
        }
        CommandGroup(replacing: .appInfo) {
            Button(L10n.t("About Lazy PDF")) {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .showAbout, object: nil)
            }
        }
        CommandGroup(replacing: .help) {
            Button(L10n.t("Lazy PDF Help")) {
                if let site = URL(string: AppInfo.site) { NSWorkspace.shared.open(site) }
            }
        }
    }

    @ViewBuilder private var viewItems: some View {
        Divider()
        Button(L10n.t("Zoom in")) { viewer.zoomIn() }
            .keyboardShortcut("=")
            .disabled(!usable)
        Button(L10n.t("Zoom out")) { viewer.zoomOut() }
            .keyboardShortcut("-")
            .disabled(!usable)
        Button(L10n.t("Actual size")) { viewer.actualSize() }
            .keyboardShortcut("0")
            .disabled(!usable)
        Button(L10n.t("Fit width")) { viewer.fitWidth() }
            .keyboardShortcut("8")
            .disabled(!usable)
        Button(L10n.t("Fit page")) { viewer.fitPage() }
            .keyboardShortcut("9")
            .disabled(!usable)
        Divider()
        Button(L10n.t("Rotate counterclockwise")) { viewer.rotation -= 90 }
            .keyboardShortcut("l")
            .disabled(!usable)
        Button(L10n.t("Rotate clockwise")) { viewer.rotation += 90 }
            .keyboardShortcut("r")
            .disabled(!usable)
        Divider()
        Toggle(L10n.t("One page"), isOn: Binding(get: { viewer.columns == 1 && !viewer.continuous },
                                               set: { if $0 { viewer.columns = 1; viewer.continuous = false } }))
            .disabled(!usable)
        Toggle(L10n.t("Two pages"), isOn: Binding(get: { viewer.columns == 2 }, set: { viewer.columns = $0 ? 2 : 1 }))
            .disabled(!usable)
        Toggle(L10n.t("Scroll continuously"), isOn: Binding(get: { viewer.continuous }, set: { viewer.continuous = $0 }))
            .disabled(!usable)
        Toggle(L10n.t("Reading mode"), isOn: Binding(get: { viewer.readingMode }, set: { viewer.readingMode = $0 }))
            .keyboardShortcut("r", modifiers: [.command, .control])
            .disabled(!usable)
        Divider()
        Menu(L10n.t("Side panels")) {
            ForEach(Array(ToolCatalog.sidePanels.enumerated()), id: \.element.id) { at, panel in
                Toggle(panel.title, isOn: Binding(get: { vm.sidePanelId == panel.id }, set: { _ in vm.setSidePanel(panel.id) }))
                    .keyboardShortcut(KeyEquivalent(Character(String(at + 1))), modifiers: [.command, .option])
            }
        }
        .disabled(!usable)
    }

    @ViewBuilder private var goItems: some View {
        Button(L10n.t("Next page")) { viewer.stepPage(1) }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!usable || viewer.pageIndex >= viewer.pageCount - 1)
        Button(L10n.t("Previous page")) { viewer.stepPage(-1) }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!usable || viewer.pageIndex <= 0)
        Button(L10n.t("First page")) { viewer.firstPage() }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            .disabled(!usable)
        Button(L10n.t("Last page")) { viewer.lastPage() }
            .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
            .disabled(!usable)
        Button(L10n.t("Go to page")) { viewer.showGoToPage() }
            .keyboardShortcut("g", modifiers: [.command, .option])
            .disabled(!usable)
        Divider()
        Button(L10n.t("Back")) { viewer.goBack() }
            .keyboardShortcut("[")
            .disabled(!viewer.canGoBack || !free)
        Button(L10n.t("Forward")) { viewer.goForward() }
            .keyboardShortcut("]")
            .disabled(!viewer.canGoForward || !free)
    }
}
#endif
