#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The inspector content for a tool (windows/LazyPDF.App/MainWindow.Tools.cs): the panel the registry has for it, attached to
// the document while it is on screen. A tool nobody has ported yet shows its title and what it is for. The window puts this
// in its scrolling inspector, or in the sheet of the compact layout, and pins the button of `ToolPanels.action(for:)` under it.

public struct ToolHostView: View {
    let id: String
    let tab: DocumentTab
    let viewer: DocumentViewer
    let panels: ToolPanels
    @State private var panel: ToolPanel?

    public init(id: String, tab: DocumentTab, viewer: DocumentViewer, panels: ToolPanels) {
        self.id = id
        self.tab = tab
        self.viewer = viewer
        self.panels = panels
    }

    public var body: some View {
        Group {
            if let panel {
                panel.view
            } else {
                ToolSummaryView(id: id)
            }
        }
        .onAppear {
            guard let made = panel ?? panels.make(id) else { return }
            panel = made
            panels.show(made, id: id, tab: tab, viewer: viewer)
        }
        .onDisappear {
            if let panel { panels.leave(panel) }
        }
    }
}

struct ToolSummaryView: View {
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
