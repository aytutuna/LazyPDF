#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the content group: editcontent, stamps.

extension ToolRegistry {
    static func content(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "editcontent": return ToolPanel(EditContentModel()) { EditContentPanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
