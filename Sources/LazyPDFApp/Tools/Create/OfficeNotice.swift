import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Create/OfficeNotice.cs.

enum OfficeNotice {
    /// The note under a PDF made from an Office file: it can differ from the program that made the file, and what was left out.
    static func text(_ made: MadePdf, _ app: OfficeApp?) -> String {
        var left = made.skipped.sorted { $0.kind.utf8.lexicographicallyPrecedes($1.kind.utf8) }.map { name($0.kind) }
        if made.unreadable > 0 { left.append(L10n.t("letters no font has")) }
        let text = app == .excel ? L10n.t("Layout can differ from Excel.") : L10n.t("Layout can differ from Word.")
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
        case "hidden-sheet": return L10n.t("hidden sheets")
        case "chart-sheet": return L10n.t("chart sheets")
        case "other-sheet": return L10n.t("sheets that are not worksheets")
        case "rich-text": return L10n.t("formatting inside cells (first style used)")
        case "fill-pattern": return L10n.t("pattern and gradient fills")
        case "text-rotation": return L10n.t("rotated text (shown straight)")
        case "formula-no-value": return L10n.t("formulas without a saved result (shown empty)")
        case "cell-outside-grid": return L10n.t("cells beyond the sheet limits")
        case "long-text": return L10n.t("text cut at the cell limit")
        case "sheet-picture": return L10n.t("pictures on sheets")
        case "sheet-chart": return L10n.t("charts on sheets")
        case "sheet-shape": return L10n.t("shapes on sheets")
        case "conditional-format": return L10n.t("conditional formatting")
        case "sparkline": return L10n.t("sparklines")
        case "data-validation": return L10n.t("data validation")
        case "sheet-comment": return L10n.t("cell comments")
        case "rtl-text": return L10n.t("right-to-left text direction")
        case "complex-script": return L10n.t("complex-script shaping")
        default: return kind
        }
    }
}
