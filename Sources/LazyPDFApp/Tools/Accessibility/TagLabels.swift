import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Accessibility/TagLabels.cs.

/// How an element of the tag tree reads in the tree view.
public enum TagLabels {
    public static func of(_ element: StructElement, _ tree: StructureTree) -> String {
        let standard = tree.standardType(element.type)
        var name = standard == element.type || standard.isEmpty ? element.type : element.type + " (" + standard + ")"
        if name.isEmpty { name = L10n.t("Untitled tag") }
        let text = note(element)
        let page = FigureFinder.pageOf(element)
        let at = page >= 0 ? L10n.t(", page {0}", page + 1) : ""
        return text.isEmpty ? name + at : name + at + ": " + text
    }

    public static func of(_ kid: StructKid, _ tree: StructureTree) -> String {
        switch kid {
        case let element as StructElement:
            return of(element, tree)
        case let content as StructContent:
            return content.pageIndex >= 0 ? L10n.t("Marked content, page {0}", content.pageIndex + 1) : L10n.t("Marked content")
        case let target as StructObject:
            return target.pageIndex >= 0 ? L10n.t("Annotation, page {0}", target.pageIndex + 1) : L10n.t("Annotation")
        default:
            return L10n.t("Annotation")
        }
    }

    private static func note(_ element: StructElement) -> String {
        for text in [element.alt, element.actualText, element.title] {
            guard let text else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.count > 60 ? String(trimmed.prefix(60)) + "..." : trimmed }
        }
        return ""
    }
}

/// The lines of the reading order, and what a voice should say for each.
public enum ReadingLines {
    public static func of(_ order: String) -> [String] {
        order.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The line without the marks that only show structure: heading hashes, figure brackets, tabs between cells.
    public static func spoken(_ line: String) -> String {
        var text = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        return text.replacingOccurrences(of: "\t", with: ",")
    }
}
