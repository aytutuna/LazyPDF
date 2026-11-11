import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Combine/CombineEntry.cs: a file in the list to combine. `document` is nil for the open
// document, which is read again when the work starts.

@MainActor
@Observable
public final class CombineEntry: Identifiable {
    public let id = UUID()
    public let name: String
    public let document: PdfDocument?
    public let path: String?

    /// Pages to take, as typed ("1-3, 5"); empty takes all.
    public var range = ""

    public var pages: Int

    public init(_ name: String, _ pages: Int, _ document: PdfDocument?, path: String? = nil) {
        self.name = name
        self.pages = pages
        self.document = document
        self.path = path
    }

    public var detail: String { L10n.plural(pages, one: "{0} page", other: "{0} pages") }

    public var title: String { URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent }
    public var rangeName: String { L10n.t("Pages of {0}", name) }
}
