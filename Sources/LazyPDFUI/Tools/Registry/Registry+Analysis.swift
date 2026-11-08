#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the analysis group: ocr, compare, accessibility.

extension ToolRegistry {
    static func analysis(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        default: return nil
        }
    }
}
#endif
