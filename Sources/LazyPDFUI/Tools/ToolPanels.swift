#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The panel in the inspector, as MainWindow.Tools.cs keeps it (_inspectorPanel, Place, RefreshAction): one at a time, attached
// to the document in view for as long as it is shown. The window asks it for the pinned button; the Save, Undo and Close
// commands ask it to hand in what is still being typed.

@MainActor
@Observable
public final class ToolPanels {
    private struct Shown {
        let id: String
        let panel: ToolPanel
        let viewer: DocumentViewer
    }

    @ObservationIgnored private let host: ToolHost
    @ObservationIgnored private let folders: AppFolders
    @ObservationIgnored private var made: [String: ToolPanel] = [:]
    private var current: Shown?

    public init(host: ToolHost, folders: AppFolders) {
        self.host = host
        self.folders = folders
    }

    // One panel for each tool for as long as the window lives, as _panels of the Windows window: what is set in a panel is
    // there when the tool is shown again, and the model attaches to whichever document is in view.
    func panel(_ id: String) -> ToolPanel? {
        if let known = made[id] { return known }
        guard let info = ToolCatalog.find(id),
              let panel = ToolRegistry.panel(for: id, ToolContext(info: info, folders: folders)) else { return nil }
        made[id] = panel
        return panel
    }

    // The panel that was shown is detached first, so it does not matter in which order the views of two tools come and go.
    // The viewer shows the document before the panel attaches, whichever the window got to first: a tool reads the pages
    // and draws its marks as it attaches, and showing a document clears the marks.
    func show(_ panel: ToolPanel, id: String, tab: DocumentTab, viewer: DocumentViewer) {
        release()
        if viewer.tab !== tab { viewer.show(tab) }
        panel.model.attach(tab, viewer, host)
        current = Shown(id: id, panel: panel, viewer: viewer)
    }

    // A panel that was replaced has been detached already.
    func leave(_ panel: ToolPanel) {
        if current?.panel.model === panel.model { release() }
    }

    // The tool's marks go and its open fields end, then its pointer goes back to the viewer, whether or not the tool did it
    // itself. The fields end before the model detaches, so their text still has a document to go to.
    private func release() {
        guard let old = current else { return }
        current = nil
        old.viewer.endToolMarks(prefix: "\(old.id).")
        old.panel.model.detach()
        old.viewer.pointerTool = nil
        host.holdStage(false)
    }

    /// The pinned button of the tool `id`, if its panel is the one shown.
    public func action(for id: String) -> ToolAction? {
        current?.id == id ? current?.panel.model.action : nil
    }

    /// The stage view of the panel shown, while the tool holds the stage.
    public var stage: AnyView? { current?.panel.stage }

    /// False when the panel's typing waits for an answer.
    public func handIn() -> Bool {
        current?.panel.model.handIn() ?? true
    }

    public func handInOnSwitch() -> Bool {
        current?.panel.model.handInOnSwitch() ?? true
    }
}
#endif
