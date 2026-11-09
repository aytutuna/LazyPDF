#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the convert group: optimize, export, create, batch.

extension ToolRegistry {
    static func convert(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "optimize": return ToolPanel(OptimizeModel(codec: ImageIOCodec())) { OptimizePanelView(model: $0) }
        case "export":
            return ToolPanel(ExportModel(codec: ImageIOCodec(), renderers: { PdfKitRenderer() }, reveal: RevealInFinder.action)) { ExportPanelView(model: $0) }
        case "create":
            return ToolPanel(CreatePanelModel(codec: ImageIOCodec(), fonts: CoreTextFontSource())) { CreatePanelView(model: $0.create) }
        default: return nil
        }
    }
}
#endif
