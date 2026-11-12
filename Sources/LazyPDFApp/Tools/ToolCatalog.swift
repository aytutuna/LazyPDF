import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/ToolCatalog.cs. The panels are made by the apps' own code, which looks them up by id,
// so the catalog holds only what the shell lists.

/// The groups of the tool strip, in the order it shows them.
public enum ToolGroup: CaseIterable, Sendable {
    case review, edit, organize, formsAndSignatures, security, createAndExport, optimize, check
}

/// A tool of the inspector. `id` is stable and lower-case; the home tiles and the saved settings refer to it. `symbol` is
/// an SF Symbol name and `summary` one sentence for the help text and the panel's first line.
public struct ToolInfo: Equatable, Sendable {
    public let id: String
    public let group: ToolGroup
    public let title: String
    public let symbol: String
    public let summary: String
}

/// A panel of the rail beside the stage.
public struct SidePanelInfo: Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let summary: String
}

/// Every tool, in the groups of the tool strip, and the side panels of the rail.
public enum ToolCatalog {
    public static var tools: [ToolInfo] {
        [
            ToolInfo(id: "comment", group: .review, title: L10n.t("Comment"), symbol: "bubble.left",
                     summary: L10n.t("Highlight, draw and leave notes on the pages.")),
            ToolInfo(id: "measure", group: .review, title: L10n.t("Measure"), symbol: "ruler",
                     summary: L10n.t("Measure distances, perimeters and areas on a page.")),
            ToolInfo(id: "compare", group: .review, title: L10n.t("Compare files"), symbol: "rectangle.split.2x1",
                     summary: L10n.t("Show what changed between two files.")),
            ToolInfo(id: "editcontent", group: .edit, title: L10n.t("Edit text and pictures"), symbol: "pencil",
                     summary: L10n.t("Change the words and pictures already on a page.")),
            ToolInfo(id: "stamps", group: .edit, title: L10n.t("Stamps and watermarks"), symbol: "seal",
                     summary: L10n.t("Add a stamp, a watermark, page numbers or a header.")),
            ToolInfo(id: "pages", group: .organize, title: L10n.t("Organize pages"), symbol: "doc.on.doc",
                     summary: L10n.t("Rotate, move, delete, crop and extract pages.")),
            ToolInfo(id: "combine", group: .organize, title: L10n.t("Combine files"), symbol: "square.on.square",
                     summary: L10n.t("Join files into a new one, or split this one.")),
            ToolInfo(id: "batch", group: .organize, title: L10n.t("Batch"), symbol: "square.stack.3d.up",
                     summary: L10n.t("Do the same to every file in a folder.")),
            ToolInfo(id: "forms", group: .formsAndSignatures, title: L10n.t("Form fields"), symbol: "list.bullet.rectangle",
                     summary: L10n.t("Fill in, add, change and flatten form fields.")),
            ToolInfo(id: "fillsign", group: .formsAndSignatures, title: L10n.t("Fill and sign"), symbol: "signature",
                     summary: L10n.t("Sign, initial, or add text and a date.")),
            ToolInfo(id: "certificates", group: .formsAndSignatures, title: L10n.t("Certificates"), symbol: "checkmark.seal",
                     summary: L10n.t("Sign with a certificate and check the signatures of a file.")),
            ToolInfo(id: "protect", group: .security, title: L10n.t("Protect"), symbol: "lock",
                     summary: L10n.t("Set a password and decide what others may do.")),
            ToolInfo(id: "redact", group: .security, title: L10n.t("Redact"), symbol: "eye.slash",
                     summary: L10n.t("Remove text and pictures from the file for good.")),
            ToolInfo(id: "sanitize", group: .security, title: L10n.t("Clean for sharing"), symbol: "eraser",
                     summary: L10n.t("Take out hidden data before the file goes to someone else.")),
            ToolInfo(id: "create", group: .createAndExport, title: L10n.t("Create"), symbol: "doc.badge.plus",
                     summary: L10n.t("Make a PDF from blank pages, pictures, text or the clipboard.")),
            ToolInfo(id: "export", group: .createAndExport, title: L10n.t("Export"), symbol: "square.and.arrow.up",
                     summary: L10n.t("Save as Word, Excel, PowerPoint, HTML, text or pictures.")),
            ToolInfo(id: "optimize", group: .optimize, title: L10n.t("Make smaller"), symbol: "arrow.down.right.and.arrow.up.left",
                     summary: L10n.t("Shrink the file and see where its space goes.")),
            ToolInfo(id: "ocr", group: .optimize, title: L10n.t("Make searchable"), symbol: "text.viewfinder",
                     summary: L10n.t("Recognize the text of scanned pages.")),
            ToolInfo(id: "metadata", group: .check, title: L10n.t("Properties"), symbol: "info.circle",
                     summary: L10n.t("Title, author and the other facts stored in the file.")),
            ToolInfo(id: "accessibility", group: .check, title: L10n.t("Accessibility"), symbol: "accessibility",
                     summary: L10n.t("Check the file for screen readers and fix what is missing.")),
            ToolInfo(id: "standards", group: .check, title: L10n.t("PDF/A"), symbol: "checkmark.shield",
                     summary: L10n.t("Check the file against PDF/A and convert it.")),
        ]
    }

    public static var sidePanels: [SidePanelInfo] {
        [
            SidePanelInfo(id: "pages", title: L10n.t("Pages"), symbol: "rectangle.grid.1x2", summary: L10n.t("Thumbnails of every page.")),
            SidePanelInfo(id: "bookmarks", title: L10n.t("Bookmarks"), symbol: "bookmark", summary: L10n.t("The bookmarks of the file.")),
            SidePanelInfo(id: "attachments", title: L10n.t("Attachments"), symbol: "paperclip", summary: L10n.t("Files carried inside this one.")),
            SidePanelInfo(id: "layers", title: L10n.t("Layers"), symbol: "square.stack.3d.up",
                          summary: L10n.t("Parts of the pages that can be shown or hidden.")),
            SidePanelInfo(id: "comments", title: L10n.t("Comments"), symbol: "text.bubble", summary: L10n.t("Every note and mark, with replies.")),
            SidePanelInfo(id: "signatures", title: L10n.t("Signatures"), symbol: "signature",
                          summary: L10n.t("Who signed the file and whether it changed since.")),
            SidePanelInfo(id: "search", title: L10n.t("Search"), symbol: "magnifyingglass", summary: L10n.t("Search for words in the file.")),
        ]
    }

    public static func find(_ id: String) -> ToolInfo? {
        tools.first { $0.id == id }
    }

    /// The tools whose title or summary holds every word of `text`, ignoring case and accents; all of them for no words.
    public static func search(_ text: String) -> [ToolInfo] {
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        return tools.filter { tool in
            let hay = (tool.title + " " + tool.summary).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return words.allSatisfy { hay.contains($0) }
        }
    }

    public static func findSide(_ id: String) -> SidePanelInfo? {
        sidePanels.first { $0.id == id }
    }

    public static func groupTitle(_ group: ToolGroup) -> String {
        switch group {
        case .review: return L10n.t("Review")
        case .edit: return L10n.t("Edit")
        case .organize: return L10n.t("Organize")
        case .formsAndSignatures: return L10n.t("Forms and signatures")
        case .security: return L10n.t("Security")
        case .createAndExport: return L10n.t("Create and export")
        case .optimize: return L10n.t("Optimize")
        case .check: return L10n.t("Check")
        }
    }

    public static func groupSymbol(_ group: ToolGroup) -> String {
        switch group {
        case .review: return "bubble.left"
        case .edit: return "pencil"
        case .organize: return "doc.on.doc"
        case .formsAndSignatures: return "signature"
        case .security: return "lock"
        case .createAndExport: return "square.and.arrow.up"
        case .optimize: return "arrow.down.right.and.arrow.up.left"
        case .check: return "checkmark.shield"
        }
    }
}
