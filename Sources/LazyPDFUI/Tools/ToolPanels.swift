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
    private var current: Shown?

    public init(host: ToolHost, folders: AppFolders) {
        self.host = host
        self.folders = folders
    }

    func make(_ id: String) -> ToolPanel? {
        guard let info = ToolCatalog.find(id) else { return nil }
        return ToolRegistry.panel(for: id, ToolContext(info: info, folders: folders))
    }

    // The panel that was shown is detached first, so it does not matter in which order the views of two tools come and go.
    func show(_ panel: ToolPanel, id: String, tab: DocumentTab, viewer: DocumentViewer) {
        release()
        panel.model.attach(tab, viewer, host)
        current = Shown(id: id, panel: panel, viewer: viewer)
    }

    // A panel that was replaced has been detached already.
    func leave(_ panel: ToolPanel) {
        if current?.panel.model === panel.model { release() }
    }

    // The tool's pointer goes back to the viewer, whether or not the tool gave it up itself.
    private func release() {
        guard let old = current else { return }
        current = nil
        old.panel.model.detach()
        old.viewer.pointerTool = nil
    }

    /// The pinned button of the tool `id`, if its panel is the one shown.
    public func action(for id: String) -> ToolAction? {
        current?.id == id ? current?.panel.model.action : nil
    }

    /// False when the panel's typing waits for an answer.
    public func handIn() -> Bool {
        current?.panel.model.handIn() ?? true
    }
}
#endif
