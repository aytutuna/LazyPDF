import Foundation

// Follows windows/LazyPDF.App/Tools/Create/ClipboardContent.cs, on host.clipboard.

public enum ClipboardKind { case nothing, text, picture }

/// What the pasteboard holds that a page can be made of: text, else a picture as PNG or TIFF.
public struct ClipboardContent {
    public let text: String?
    public let picture: [UInt8]?

    @MainActor
    public static func read(_ clipboard: ToolClipboard) -> ClipboardContent {
        if let text = clipboard.text(), !text.isEmpty { return ClipboardContent(text: text, picture: nil) }
        if let picture = clipboard.pictureFile() { return ClipboardContent(text: nil, picture: picture) }
        return ClipboardContent(text: nil, picture: nil)
    }

    public var kind: ClipboardKind { text != nil ? .text : picture != nil ? .picture : .nothing }
}
