#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The tools of the security group: protect, redact, certificates, standards.

// What the engine needs of the system for fonts and pictures; the shells hand the same ones to the window.
private enum SystemKit {
    static var fonts: FontSource? {
        #if canImport(CoreText)
        return CoreTextFontSource()
        #else
        return nil
        #endif
    }

    static var images: ImageCodec? {
        #if canImport(ImageIO)
        return ImageIOCodec()
        #else
        return nil
        #endif
    }
}

extension ToolRegistry {
    static func security(_ id: String, _ context: ToolContext) -> ToolPanel? {
        switch id {
        case "protect": return ToolPanel(ProtectModel()) { ProtectPanelView(model: $0) }
        case "redact": return ToolPanel(RedactModel(fonts: SystemKit.fonts, images: SystemKit.images)) { RedactPanelView(model: $0) }
        case "standards": return ToolPanel(StandardsModel(fonts: SystemKit.fonts)) { StandardsPanelView(model: $0) }
        default: return nil
        }
    }
}
#endif
