#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools about the file as a whole: Properties and Clean for sharing. They are the examples the other groups follow.

extension ToolRegistry {
    static func document(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "metadata": return ToolPanel(MetadataModel()) { MetadataPanelView(model: $0) }
        case "sanitize": return ToolPanel(SanitizeModel()) { SanitizePanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
