#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

/// The side panel `id` for the document of `tab`: makes the panel's model, attaches it while the view is shown and detaches
/// it when the view goes. The shell puts it in the side pane; a different panel or document makes a new one.
public struct SidePanelView: View {
    let id: String
    let tab: DocumentTab
    let viewer: DocumentViewer
    let host: ToolHost
    let folders: AppFolders

    public init(id: String, tab: DocumentTab, viewer: DocumentViewer, host: ToolHost, folders: AppFolders = DefaultAppFolders()) {
        self.id = id
        self.tab = tab
        self.viewer = viewer
        self.host = host
        self.folders = folders
    }

    public var body: some View {
        SidePanelContent(id: id, tab: tab, viewer: viewer, host: host, folders: folders)
            .id(id + "/" + tab.id.uuidString)
    }
}

private struct SidePanelContent: View {
    let id: String
    let tab: DocumentTab
    let viewer: DocumentViewer
    let host: ToolHost
    let folders: AppFolders
    @State private var model: ToolPanelModel?

    var body: some View {
        content
            .onAppear {
                let made = model ?? SidePanelCatalog.create(id, folders)
                model = made
                made?.attach(tab, viewer, host)
            }
            .onDisappear { model?.detach() }
    }

    @ViewBuilder
    private var content: some View {
        switch model {
        case let model as PagesModel: PagesPanelView(model: model)
        case let model as BookmarksModel: BookmarksPanelView(model: model)
        case let model as AttachmentsModel: AttachmentsPanelView(model: model)
        case let model as LayersModel: LayersPanelView(model: model)
        case let model as CommentsModel: CommentsPanelView(model: model)
        case let model as SignaturesModel: SignaturesPanelView(model: model)
        case let model as SearchModel: SearchPanelView(model: model)
        default: EmptyView()
        }
    }
}
#endif
