#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the convert group: optimize, export, create, batch.

extension ToolRegistry {
    static func convert(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "optimize": return ToolPanel(OptimizeModel(codec: ImageIOCodec())) { OptimizePanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
