#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the markup group: comment, measure.

extension ToolRegistry {
    #if os(iOS)
    private static let touch = true
    #else
    private static let touch = false
    #endif

    static func markup(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "comment": return ToolPanel(CommentModel(fonts: CoreTextFontSource(), touch: Self.touch)) { CommentPanelView(model: $0) }
        case "measure": return ToolPanel(MeasureModel(fonts: CoreTextFontSource(), touch: Self.touch)) { MeasurePanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
