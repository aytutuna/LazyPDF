import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Create/WordNotice.cs.

enum WordNotice {
    /// The note under a PDF made from a Word file: it can differ from Word, and what was left out.
    static func text(_ made: MadePdf) -> String {
        var left = made.skipped.sorted { $0.kind.utf8.lexicographicallyPrecedes($1.kind.utf8) }.map { name($0.kind) }
        if made.unreadable > 0 { left.append(L10n.t("letters no font has")) }
        let text = L10n.t("Layout can differ from Word.")
        return left.isEmpty ? text : text + " " + L10n.t("Left out: {0}.", left.joined(separator: ", "))
    }

    private static func name(_ kind: String) -> String {
        switch kind {
        case "table": return L10n.t("tables too large or nested (shown as paragraphs)")
        case "text-box": return L10n.t("text boxes")
        case "picture": return L10n.t("pictures that could not be read")
        case "chart": return L10n.t("charts")
        case "shape": return L10n.t("shapes")
        case "drawing": return L10n.t("drawings")
        case "footnote": return L10n.t("footnotes")
        case "endnote": return L10n.t("endnotes")
        case "comment": return L10n.t("comment marks")
        case "equation": return L10n.t("equations")
        case "tracked-change": return L10n.t("tracked changes")
        case "field": return L10n.t("fields (shown as last saved)")
        case "floating-picture": return L10n.t("picture positions (placed in line)")
        case "rtl-text": return L10n.t("right-to-left text direction")
        case "complex-script": return L10n.t("complex-script shaping")
        default: return kind
        }
    }
}
