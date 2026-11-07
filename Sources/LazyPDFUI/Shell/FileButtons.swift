#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The file buttons of the tab bar and the tool strip under it (MainWindow.Files.cs, MainWindow.Tools.cs). The keyboard
// shortcuts sit on the buttons, as the Windows accelerators sit on the window: Open, Save, Save as, Undo, Redo and Print.

/// What the file buttons do. Saving to a name and saving compact go through the platform shell's panels.
@MainActor
struct FileActions {
    let vm: AppViewModel
    let commands: ShellCommands

    func save() {
        guard let tab = vm.activeDocument else { return }
        if AppViewModel.needsName(tab) { saveAs() } else { vm.save(tab) }
    }

    func saveAs() {
        guard let tab = vm.activeDocument else { return }
        Task { _ = await commands.saveAs(tab) }
    }

    func saveCompact() {
        guard let tab = vm.activeDocument else { return }
        let commands = commands
        if tab.document.isSigned {
            vm.showNotice(L10n.t("Signatures would be lost"),
                          L10n.t("{0} is signed. Saving it compact writes it again and the signatures no longer hold. Save and Save as keep them.", tab.title),
                          NoticeAction(L10n.t("Save compact anyway")) { commands.saveCompact(tab) })
        } else {
            commands.saveCompact(tab)
        }
    }

    func print() {
        vm.print()
    }

    // Cmd+Z belongs to the text being typed in while there is one, as the Windows window skips Z and Y for a text box.
    func undo() {
        if !EditFocus.undoInText(redo: false) { vm.undo() }
    }

    func redo() {
        if !EditFocus.undoInText(redo: true) { vm.redo() }
    }

    /// The Save of the close question: a tab with no file asks for a name first. The tab closes once it is saved.
    func saveAndClose(_ tab: DocumentTab) async {
        let saved: Bool
        if AppViewModel.needsName(tab) {
            vm.select(tab)
            saved = await commands.saveAs(tab)
        } else {
            saved = vm.save(tab)
        }
        if saved {
            vm.close(tab)
        } else if vm.message?.action != nil {
            vm.cancelClose()
        }
    }

    var undoHelp: String {
        vm.undoLabel.flatMap { $0.isEmpty ? nil : L10n.t("Undo {0}", $0) } ?? L10n.t("Undo")
    }

    var redoHelp: String {
        vm.redoLabel.flatMap { $0.isEmpty ? nil : L10n.t("Redo {0}", $0) } ?? L10n.t("Redo")
    }
}

struct FileButtons: View {
    let vm: AppViewModel
    let commands: ShellCommands
    let settings: () -> Void

    var body: some View {
        let actions = FileActions(vm: vm, commands: commands)
        let hasDocument = vm.activeDocument != nil
        HStack(spacing: 2) {
            icon("folder", L10n.t("Open a file")) { commands.open() }
                .keyboardShortcut("o")
            icon("square.and.arrow.down", L10n.t("Save"), actions.save)
                .keyboardShortcut("s")
                .disabled(!hasDocument || vm.isBusy)
            Menu {
                Button(L10n.t("Save as…"), action: actions.saveAs)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button(L10n.t("Save compact…"), action: actions.saveCompact)
                    .help(L10n.t("Writes the file again without its history of changes."))
            } label: {
                Image(systemName: "chevron.down").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!hasDocument || vm.isBusy)
            .help(L10n.t("More ways to save"))
            .accessibilityLabel(L10n.t("More ways to save"))
            Divider().frame(height: 16).padding(.horizontal, 4)
            icon("arrow.uturn.backward", actions.undoHelp, actions.undo)
                .keyboardShortcut("z")
                .disabled(!vm.canUndo || vm.isBusy)
            icon("arrow.uturn.forward", actions.redoHelp, actions.redo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!vm.canRedo || vm.isBusy)
            icon("printer", L10n.t("Print"), actions.print)
                .keyboardShortcut("p")
                .disabled(!hasDocument)
            Divider().frame(height: 16).padding(.horizontal, 4)
            icon("gearshape", L10n.t("Settings"), settings)
        }
    }

    private func icon(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct ToolStrip: View {
    let vm: AppViewModel
    let iconsOnly: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ToolGroup.allCases, id: \.self) { group in
                groupMenu(group)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Tools"))
    }

    private func groupMenu(_ group: ToolGroup) -> some View {
        let on = vm.activeTool?.group == group
        let title = ToolCatalog.groupTitle(group)
        return Menu {
            ForEach(ToolCatalog.tools.filter { $0.group == group }, id: \.id) { tool in
                Toggle(isOn: Binding(get: { vm.activeToolId == tool.id }, set: { _ in vm.selectTool(tool.id) })) {
                    Label(tool.title, systemImage: tool.symbol)
                }
                .help(tool.summary)
            }
        } label: {
            if iconsOnly {
                Image(systemName: ToolCatalog.groupSymbol(group))
            } else {
                Label(title, systemImage: ToolCatalog.groupSymbol(group))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .fontWeight(on ? .semibold : .regular)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(on ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .help(title)
        .accessibilityLabel(title)
    }
}
#endif
