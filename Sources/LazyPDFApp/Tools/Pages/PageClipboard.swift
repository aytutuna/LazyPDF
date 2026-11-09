import Foundation
import Observation

// Follows windows/LazyPDF.App/Tools/Pages/PageClipboard.cs: pages cut or copied in the organize view, as a PDF of just those
// pages, for pasting into any open tab. The pasteboard of the system holds pictures and text only (ToolClipboard), so the
// pages wait here, in the app.

@MainActor
@Observable
public final class PageClipboard {
    public static let shared = PageClipboard()

    public private(set) var pdf: [UInt8]?
    public private(set) var count = 0

    public init() {}

    public func set(_ pdf: [UInt8], _ count: Int) {
        self.pdf = pdf
        self.count = count
    }
}
