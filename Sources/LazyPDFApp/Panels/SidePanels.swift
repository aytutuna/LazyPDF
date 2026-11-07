import Foundation
import LazyPDFKit

// Twin of SidePanelInfo and ToolCatalog.SidePanels in windows/LazyPDF.App/Tools/ToolCatalog.cs. The symbols are SF Symbols.

/// A panel on the rail beside the stage. `create` makes the model the first time the panel is shown.
public struct SidePanelInfo {
    public let id: String
    public let title: String
    public let symbol: String
    public let summary: String
    public let create: @MainActor (AppFolders) -> ToolPanelModel
}

public enum SidePanelCatalog {
    /// In the order of the rail; "pages" is first.
    public static var all: [SidePanelInfo] {
        [
            SidePanelInfo(id: "pages", title: L10n.t("Pages"), symbol: "rectangle.grid.1x2", summary: L10n.t("Thumbnails of every page."),
                          create: { _ in PagesModel() }),
            SidePanelInfo(id: "bookmarks", title: L10n.t("Bookmarks"), symbol: "bookmark", summary: L10n.t("The bookmarks of the file."),
                          create: { _ in BookmarksModel() }),
            SidePanelInfo(id: "attachments", title: L10n.t("Attachments"), symbol: "paperclip", summary: L10n.t("Files carried inside this one."),
                          create: { AttachmentsModel(openedFolder: $0.openedAttachments) }),
            SidePanelInfo(id: "layers", title: L10n.t("Layers"), symbol: "square.3.layers.3d",
                          summary: L10n.t("Parts of the pages that can be shown or hidden."), create: { _ in LayersModel() }),
            SidePanelInfo(id: "comments", title: L10n.t("Comments"), symbol: "text.bubble", summary: L10n.t("Every note and mark, with replies."),
                          create: { _ in CommentsModel() }),
            SidePanelInfo(id: "signatures", title: L10n.t("Signatures"), symbol: "signature",
                          summary: L10n.t("Who signed the file and whether it changed since."),
                          create: { SignaturesModel(trust: SignatureTrust(directory: $0.settings)) }),
            SidePanelInfo(id: "search", title: L10n.t("Search"), symbol: "magnifyingglass", summary: L10n.t("Search for words in the file."),
                          create: { _ in SearchModel() }),
        ]
    }

    public static func find(_ id: String) -> SidePanelInfo? {
        all.first { $0.id == id }
    }
}
