import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Metadata/MetadataEdit.cs: writing the properties and the opening view of a file, and the
// words for their choices.

public enum MetadataEdit {
    public static let modes: [PageMode] = [.useNone, .useOutlines, .useThumbs, .fullScreen, .useOC, .useAttachments]

    public static let layouts: [PageLayout] = [.singlePage, .oneColumn, .twoColumnLeft, .twoColumnRight, .twoPageLeft, .twoPageRight]

    /// The /Duplex names; nil leaves it to the printer.
    public static let sides: [String?] = [nil, "Simplex", "DuplexFlipLongEdge", "DuplexFlipShortEdge"]

    /// Stores both. The changed date becomes `now` when `touchModified` is set.
    public static func write(_ document: PdfDocument, _ metadata: DocumentMetadata, _ view: ViewerSettings, touchModified: Bool,
                             now: DateTimeOffset) throws {
        var stored = metadata
        if touchModified { stored.modified = now }
        try stored.write(document)
        view.write(document)
    }

    /// An earlier title, author, subject or keywords stays in the file's older revisions when it is cleared or changed.
    public static func dropsText(_ before: DocumentMetadata, _ after: DocumentMetadata) -> Bool {
        func drops(_ old: String?, _ new: String?) -> Bool { !(old ?? "").isEmpty && old != new }
        return drops(before.title, after.title) || drops(before.author, after.author) || drops(before.subject, after.subject)
            || drops(before.keywords, after.keywords)
    }

    public static func modeName(_ mode: PageMode) -> String {
        switch mode {
        case .useOutlines: return L10n.t("Bookmarks")
        case .useThumbs: return L10n.t("Page thumbnails")
        case .fullScreen: return L10n.t("Full screen")
        case .useOC: return L10n.t("Layers")
        case .useAttachments: return L10n.t("Attachments")
        case .useNone: return L10n.t("Nothing, just the page")
        }
    }

    public static func layoutName(_ layout: PageLayout) -> String {
        switch layout {
        case .oneColumn: return L10n.t("Scrolling, one page across")
        case .twoColumnLeft: return L10n.t("Scrolling, two pages across")
        case .twoColumnRight: return L10n.t("Scrolling, two pages, cover alone")
        case .twoPageLeft: return L10n.t("Two pages at a time")
        case .twoPageRight: return L10n.t("Two pages at a time, cover alone")
        case .singlePage: return L10n.t("One page at a time")
        }
    }

    public static func sidesName(_ duplex: String?) -> String {
        switch duplex {
        case "Simplex": return L10n.t("One side")
        case "DuplexFlipLongEdge": return L10n.t("Both sides, long edge")
        case "DuplexFlipShortEdge": return L10n.t("Both sides, short edge")
        default: return L10n.t("Printer default")
        }
    }
}
