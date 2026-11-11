#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/MainWindow.xaml and its partial files, on AppViewModel. Wide: the tab strip over a rail, the
// side pane, the stage and the inspector, side by side. Narrow (the iPhone): the stage full screen with a document menu in
// place of the tab strip, and the side panels and the tools as sheets.
//
// The three slots are filled in by the app: the stage shows a document, the side pane a panel of the rail, the inspector a
// tool. Each is made again when the tab or the id changes (`id`), so a view can attach its model in onAppear and detach it
// in onDisappear, as the shell of the Windows app does.

private struct StageBottom: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

public struct AppWindow<Stage: View, SidePane: View, Inspector: View>: View {
    // Below this width the window is laid out for a phone.
    private static var compactWidth: CGFloat { 700 }
    // Below this width the side pane and the inspector do not both fit beside the stage: the pane gives way while a tool
    // is open, and the inspector shows only for a tool.
    private static var narrowWidth: CGFloat { 900 }
    // Below this width the groups of the tool strip show their symbols only.
    private static var iconsWidth: CGFloat { 1100 }
    // The height of the lowest detent of a tool sheet: the button and a line of the panel.
    private static var smallSheet: CGFloat { 150 }

    private let vm: AppViewModel
    private let commands: ShellCommands
    private let toolAction: (String) -> ToolAction?
    private let heldStage: () -> AnyView?
    private let stage: (DocumentTab) -> Stage
    private let sidePane: (String, DocumentTab) -> SidePane
    private let inspector: (String, DocumentTab) -> Inspector

    @State private var sheet: Modal?
    @State private var compact = false
    @State private var compactPanel: String?
    @State private var toolDetent = PresentationDetent.medium
    @State private var stageBottom: CGFloat = 0
    @State private var dropTargeted = false
    @Environment(\.scenePhase) private var scenePhase

    /// - Parameter toolAction: the pinned button of the tool's panel, if it has one.
    /// - Parameter heldStage: what stands in the stage's place while a tool holds it (`AppViewModel.holdStage`).
    public init(_ vm: AppViewModel, commands: ShellCommands = ShellCommands(),
                toolAction: @escaping (String) -> ToolAction? = { _ in nil },
                heldStage: @escaping () -> AnyView? = { nil },
                @ViewBuilder stage: @escaping (DocumentTab) -> Stage,
                @ViewBuilder sidePane: @escaping (String, DocumentTab) -> SidePane,
                @ViewBuilder inspector: @escaping (String, DocumentTab) -> Inspector) {
        self.vm = vm
        self.commands = commands
        self.toolAction = toolAction
        self.heldStage = heldStage
        self.stage = stage
        self.sidePane = sidePane
        self.inspector = inspector
    }

    public var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width < Self.compactWidth {
                    compactLayout(height: proxy.size.height, bottom: proxy.frame(in: .global).maxY)
                } else {
                    regularLayout(width: proxy.size.width)
                }
            }
            .onChange(of: proxy.size.width < Self.compactWidth, initial: true) { _, now in compact = now }
        }
        .overlay { cards }
        .sheet(item: modal) { which in
            modalBody(which)
        }
        .onChange(of: vm.passwordRequest != nil) { _, asked in
            if asked { sheet = nil }
        }
        .background { shortcuts }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            if files.isEmpty { return false }
            if let open = commands.openFiles {
                open(files)
            } else {
                Task { await vm.open(files) }
            }
            return true
        } isTargeted: { dropTargeted = $0 }
        .preferredColorScheme(colorScheme)
        .onAppear {
            vm.systemPrintRequested = commands.print
            vm.checkRecovery()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.checkDisk() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in sheet = .about }
    }

    private var modal: Binding<Modal?> {
        Binding(get: {
            Modal.current(passwordAsked: vm.passwordRequest != nil, local: sheet, compact: compact,
                          toolOpen: vm.activeTool != nil && vm.activeDocument != nil,
                          panelOpen: compactPanel != nil && vm.activeDocument != nil)
        }, set: { shown in
            if shown != nil { return }
            if vm.passwordRequest != nil {
                vm.cancelPending()
            } else if sheet != nil {
                sheet = nil
            } else if compact, let tool = vm.activeToolId, vm.activeTool != nil {
                vm.selectTool(tool)
            } else {
                compactPanel = nil
            }
        })
    }

    @ViewBuilder private func modalBody(_ which: Modal) -> some View {
        switch which {
        case .password:
            if let request = vm.passwordRequest {
                PasswordSheet(vm: vm, request: request, importCertificate: commands.importCertificate)
            }
        case .settings:
            SettingsView(vm: vm, about: { sheet = .about }, done: { sheet = nil })
        case .about:
            AboutView(done: { sheet = nil })
        case .tool:
            if let tool = vm.activeTool, let tab = vm.activeDocument {
                toolSheet(tool, tab)
            }
        case .panel:
            if let id = compactPanel, let pane = ToolCatalog.findSide(id), let tab = vm.activeDocument {
                panelSheet(pane, tab)
            }
        }
    }

    private var actions: FileActions { FileActions(vm: vm, commands: commands) }

    private var colorScheme: ColorScheme? {
        switch vm.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    // The tab bar, the tool strip and the content are out of reach while a question is up or a job runs; the info bar and
    // the status line stay, since Cancel is there.
    private var frozen: Bool { vm.isBlocked }

    private var actionRunning: Bool {
        get { vm.actionRunning }
        nonmutating set { vm.actionRunning = newValue }
    }

    private func requestClose(_ tab: DocumentTab) {
        vm.requestClose(tab)
    }

    private func regularLayout(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            InfoBar(vm: vm)
            HStack(spacing: 8) {
                TabStrip(vm: vm, close: requestClose)
                if vm.documents.count > 1 {
                    DocumentSwitcher(vm: vm, showsTitle: false)
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
                FileButtons(vm: vm, commands: commands) { sheet = .settings }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .disabled(frozen)
            if let tab = vm.activeDocument {
                ToolStrip(vm: vm, iconsOnly: width < Self.iconsWidth).disabled(frozen)
                workspace(tab, narrow: width < Self.narrowWidth).disabled(frozen)
            } else {
                HomeScreen(vm: vm, chooseTile: chooseTile).disabled(frozen)
            }
            StatusBar(vm: vm)
        }
    }

    private func workspace(_ tab: DocumentTab, narrow: Bool) -> some View {
        let toolOpen = vm.activeTool != nil
        return HStack(spacing: 0) {
            Rail(vm: vm) { id in
                // The pane has no room beside an open tool on a narrow window, so the tool gives way.
                if narrow, let tool = vm.activeToolId { vm.selectTool(tool) }
                if let id { vm.setSidePanel(id) } else { vm.toggleSidePanel() }
            }
            if let pane = vm.sidePanel, !(narrow && toolOpen) {
                PaneFrame(symbol: nil, title: pane.title, closeHelp: L10n.t("Close the side panel"), close: { vm.setSidePanel(pane.id) }) {
                    sidePane(pane.id, tab).id("\(tab.id)/\(pane.id)")
                }
                .frame(width: 260)
                Divider()
            }
            stageContent(tab)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
            if toolOpen || !narrow {
                Divider()
                inspectorPane(tab)
                    .frame(width: 280)
            }
        }
    }

    @ViewBuilder private func stageContent(_ tab: DocumentTab) -> some View {
        if vm.stageHeld, let held = heldStage() {
            held
        } else {
            stage(tab)
        }
    }

    @ViewBuilder private func inspectorPane(_ tab: DocumentTab) -> some View {
        if let tool = vm.activeTool {
            VStack(spacing: 0) {
                PaneFrame(symbol: tool.symbol, title: tool.title, closeHelp: L10n.t("Close the tool"), close: { vm.selectTool(tool.id) }) {
                    toolBody(tool, tab)
                }
                footer(tool)
            }
        } else {
            PaneFrame(symbol: "info.circle", title: L10n.t("File"), closeHelp: nil, close: {}) {
                DocumentSummary(tab: tab)
            }
        }
    }

    private func toolBody(_ tool: ToolInfo, _ tab: DocumentTab) -> some View {
        ScrollView {
            inspector(tool.id, tab)
                .id("\(tab.id)/\(tool.id)")
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityLabel(L10n.t("Tools"))
    }

    @ViewBuilder private func footer(_ tool: ToolInfo) -> some View {
        if let action = toolAction(tool.id) {
            ActionFooter(action: action, running: actionRunning) {
                if actionRunning || !vm.handIn() { return }
                actionRunning = true
                Task {
                    await action.run()
                    actionRunning = false
                }
            }
        }
    }

    // The tool sheet covers the lower part of the page, so the stage ends where the sheet starts and the page is fitted to
    // what shows. A small detent keeps the page reachable and the touches go through to it up to the medium one.
    private func sheetInset(height: CGFloat, bottom: CGFloat) -> CGFloat {
        guard compact, vm.activeTool != nil, vm.activeDocument != nil else { return 0 }
        let covered: CGFloat
        if toolDetent == .medium {
            covered = height / 2
        } else if toolDetent == .height(Self.smallSheet) {
            covered = Self.smallSheet
        } else {
            return 0
        }
        return Swift.max(0, stageBottom - (bottom - covered))
    }

    private func compactLayout(height: CGFloat, bottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            InfoBar(vm: vm)
            HStack(spacing: 8) {
                DocumentSwitcher(vm: vm)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                Spacer(minLength: 0)
                compactFileMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .disabled(frozen)
            Group {
                if let tab = vm.activeDocument {
                    stageContent(tab)
                        .id(tab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HomeScreen(vm: vm, chooseTile: chooseTile)
                }
            }
            .padding(.bottom, sheetInset(height: height, bottom: bottom))
            .background(GeometryReader { Color.clear.preference(key: StageBottom.self, value: $0.frame(in: .global).maxY) })
            .onPreferenceChange(StageBottom.self) { stageBottom = $0 }
            .disabled(frozen)
            if vm.activeDocument != nil {
                compactBar.disabled(frozen)
            }
            StatusBar(vm: vm)
        }
    }

    private var compactFileMenu: some View {
        Menu {
            Button(L10n.t("Open a file")) { commands.open() }
            Button(L10n.t("Save"), action: actions.save).disabled(vm.activeDocument == nil || vm.isBusy)
            Button(L10n.t("Save as…"), action: actions.saveAs).disabled(vm.activeDocument == nil || vm.isBusy)
            Button(L10n.t("Save compact…"), action: actions.saveCompact).disabled(vm.activeDocument == nil || vm.isBusy)
            if commands.share != nil {
                Button(L10n.t("Share"), action: actions.share).disabled(vm.activeDocument == nil)
            }
            Divider()
            Button(actions.undoHelp, action: actions.undo).disabled(!vm.canUndo || vm.isBusy)
            Button(actions.redoHelp, action: actions.redo).disabled(!vm.canRedo || vm.isBusy)
            Button(vm.printLabel, action: actions.print).disabled(vm.activeDocument == nil)
            Button(L10n.t("Close")) {
                if let tab = vm.activeDocument { requestClose(tab) }
            }
            .disabled(vm.activeDocument == nil)
            Divider()
            Button(L10n.t("Settings")) { sheet = .settings }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .help(L10n.t("More"))
        .accessibilityLabel(L10n.t("More"))
    }

    private var compactBar: some View {
        HStack(spacing: 16) {
            Menu {
                ForEach(ToolCatalog.sidePanels, id: \.id) { panel in
                    Button {
                        compactPanel = panel.id
                    } label: {
                        Label(panel.title, systemImage: panel.symbol)
                    }
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel(L10n.t("Side panels"))
            Menu {
                ForEach(ToolGroup.allCases, id: \.self) { group in
                    Section(ToolCatalog.groupTitle(group)) {
                        ForEach(ToolCatalog.tools.filter { $0.group == group }, id: \.id) { tool in
                            Button {
                                vm.selectTool(tool.id)
                            } label: {
                                Label(tool.title, systemImage: tool.symbol)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel(L10n.t("Tools"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }

    private func panelSheet(_ pane: SidePanelInfo, _ tab: DocumentTab) -> some View {
        NavigationStack {
            sidePane(pane.id, tab)
                .id("\(tab.id)/\(pane.id)")
                .navigationTitle(pane.title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("Done")) { compactPanel = nil }
                            .disabled(vm.isBusy)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { InfoBar(vm: vm, announces: false) }
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(vm: vm, announces: false) }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(vm.isBusy)
    }

    private func toolSheet(_ tool: ToolInfo, _ tab: DocumentTab) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                toolBody(tool, tab)
                footer(tool)
            }
            .navigationTitle(tool.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Done")) { vm.selectTool(tool.id) }
                        .disabled(vm.isBusy || actionRunning)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { InfoBar(vm: vm, announces: false) }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(vm: vm, announces: false) }
        }
        .presentationDetents([.height(Self.smallSheet), .medium, .large], selection: $toolDetent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled(vm.isBusy || actionRunning)
    }

    private func chooseTile(_ id: String) {
        if id == AppViewModel.openTile {
            commands.open()
        } else if id == AppViewModel.createTile {
            commands.create()
        } else if id == AppViewModel.batchTile {
            commands.batch()
        } else {
            vm.startTile(id)
        }
    }

    @ViewBuilder private var cards: some View {
        if let tab = vm.closeQuestion {
            CloseCard(tab: tab, save: { Task { await actions.saveAndClose(tab) } }, discard: { vm.close(tab) }, cancel: { vm.cancelClose() })
        } else if let offer = vm.recoveryOffer {
            RecoveryCard(titles: offer.map(\.meta.title), restore: { Task { await vm.restore() } }, discard: { vm.discardRecovery() })
        } else if dropTargeted {
            Label(L10n.t("Drop files to open them"), systemImage: "arrow.down.doc")
                .font(.title3.bold())
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).padding(8))
                .allowsHitTesting(false)
        }
    }

    // Close the document, and go to the next or previous tab. The file commands are in the platform menu.
    private var shortcuts: some View {
        Group {
            Button("") { cycleTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("") { cycleTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("") {
                if let tab = vm.activeDocument { requestClose(tab) }
            }
            .keyboardShortcut("w")
        }
        .disabled(frozen)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func cycleTab(_ step: Int) {
        let strip = vm.strip
        guard let at = strip.firstIndex(where: { $0 === vm.activeTab }) else { return }
        vm.select(strip[(at + step + strip.count) % strip.count])
    }
}
#endif
