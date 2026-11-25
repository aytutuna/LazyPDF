import Foundation

extension AppViewModel {
    /// The tool whose panel the inspector shows; nil when none is open.
    public var activeTool: ToolInfo? {
        _ = version
        return activeToolId.flatMap { ToolCatalog.find($0) }
    }

    /// The side panel the rail shows; nil while the rail is collapsed.
    public var sidePanel: SidePanelInfo? {
        _ = version
        return ToolCatalog.findSide(sidePanelId)
    }
}
