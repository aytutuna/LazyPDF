import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Standards/StandardsText.cs: the words of the PDF/A panel that are not the engine's.

enum StandardsText {
    static func describe(_ level: PdfALevel) -> String {
        switch level {
        case .a1b: return L10n.t("The oldest and strictest. No transparency.")
        case .a2b: return L10n.t("Allows transparency and layers. The usual choice.")
        case .a2u: return L10n.t("Like 2b, and every character keeps its text.")
        case .a3b: return L10n.t("Like 2b, and other files may be attached.")
        case .a3u: return L10n.t("Like 3b, and every character keeps its text.")
        case .a4: return L10n.t("The newest, based on PDF 2.0.")
        }
    }

    /// What converting costs this file, said before it is done.
    static func losses(signed: Bool, encrypted: Bool) -> String {
        let signs = signed ? L10n.t("The file is signed. The new file loses the signatures.") : ""
        let password = encrypted ? L10n.t("The new file is not password protected.") : ""
        return (signs + " " + password).trimmingCharacters(in: .whitespaces)
    }

    static func convertedTitle(_ made: PdfAConversion) -> String {
        made.isClean ? L10n.t("Converted, checks passed") : L10n.t("Converted, rules still broken")
    }

    /// What was made, said with the checks' own words, then everything the conversion changed.
    static func convertedText(_ made: PdfAConversion, _ level: PdfALevel) -> String {
        let name = level.name()
        let left = IssueRow.group(made.remaining).count
        let result = left == 0
            ? L10n.t("The new file passes Lazy PDF's checks for {0}.", name)
            : L10n.t("The new file still breaks {0} rules of {1}. The panel lists them.", left, name)
        return ([result] + made.changes + [L10n.t("It is open in a new tab. Save it to keep it.")]).joined(separator: " ")
    }

    /// The name of the new tab: the file's, with the level where it passes. The level's slash is left out because a name is cut
    /// at it.
    static func convertedName(_ title: String, _ level: PdfALevel, clean: Bool) -> String {
        let mark = clean ? level.name().replacingOccurrences(of: "/", with: "-") : L10n.t("converted")
        return (title as NSString).deletingPathExtension + " (" + mark + ").pdf"
    }
}
