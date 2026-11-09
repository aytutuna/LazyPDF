#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the markup group: comment, measure.

extension ToolRegistry {
    static func markup(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "comment": return ToolPanel(CommentModel(fonts: CoreTextFontSource())) { CommentPanelView(model: $0) }
        case "measure": return ToolPanel(MeasureModel(fonts: CoreTextFontSource())) { MeasurePanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
