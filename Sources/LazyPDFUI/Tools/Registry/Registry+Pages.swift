#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the pages group: pages, combine.

extension ToolRegistry {
    static func pages(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "pages": return ToolPanel(PagesToolModel(), stage: { PagesStageView(model: $0) }) { PagesToolPanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
