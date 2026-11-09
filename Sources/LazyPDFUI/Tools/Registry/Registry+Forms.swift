#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the forms group: forms, fillsign.

extension ToolRegistry {
    static func forms(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "forms": return ToolPanel(FormsModel(fonts: CoreTextFontSource())) { FormsPanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
