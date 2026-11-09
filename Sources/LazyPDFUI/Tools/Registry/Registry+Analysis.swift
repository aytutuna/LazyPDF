#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the analysis group: ocr, compare, accessibility.

extension ToolRegistry {
    static func analysis(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "ocr": return ToolPanel(OcrModel()) { OcrPanelView(model: $0) }
        case "compare": return ToolPanel(CompareModel()) { ComparePanelView(model: $0) }
        case "accessibility": return ToolPanel(AccessibilityModel()) { AccessibilityPanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
