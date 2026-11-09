#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp

// The tools of the forms group: forms, fillsign.

extension ToolRegistry {
    static func forms(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "forms": return ToolPanel(FormsModel(fonts: CoreTextFontSource())) { FormsPanelView(model: $0) }
        case "fillsign":
            let codec = ImageIOCodec()
            let saved = SavedSignatures(directory: SavedSignatures.defaultDirectory(context.folders), codec: codec)
            let model = FillSignModel(store: saved, fonts: CoreTextFontSource(), system: SystemSignature(), codec: codec)
            return ToolPanel(model) { FillSignPanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
