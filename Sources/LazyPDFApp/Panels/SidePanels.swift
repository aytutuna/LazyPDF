import Foundation

// The models of the rail's panels, by the ids ToolCatalog.sidePanels lists.

public enum SidePanelCatalog {
    /// Makes the model the first time a panel is shown; nil for an id the rail does not have.
    @MainActor
    public static func create(_ id: String, _ folders: AppFolders) -> ToolPanelModel? {
        switch id {
        case "pages": return PagesModel()
        case "bookmarks": return BookmarksModel()
        case "attachments": return AttachmentsModel(openedFolder: folders.openedAttachments)
        case "layers": return LayersModel()
        case "comments": return CommentsModel()
        case "signatures":
            #if canImport(Darwin)
            return SignaturesModel(trust: SignatureTrust(directory: folders.settings), transport: { UrlSessionTransport() })
            #else
            return SignaturesModel(trust: SignatureTrust(directory: folders.settings))
            #endif
        case "search": return SearchModel()
        default: return nil
        }
    }
}
