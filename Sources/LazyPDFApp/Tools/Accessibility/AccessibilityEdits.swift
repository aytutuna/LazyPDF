import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Accessibility/AccessibilityEdits.cs: the changes the accessibility panel makes to a
// document, kept apart from the controls.

public enum AccessibilityEdits {
    /// Makes the fix a failed row offers; for the title and language rows, with the text of their box. False when nothing
    /// changed. A language that is not a tag throws `ArgumentException`.
    public static func apply(_ document: PdfDocument, _ row: CheckRow) throws -> Bool {
        let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch row.editor {
        case .title:
            if value.isEmpty { return false }
            return try AccessibilityChecker.fix(document, .setTitle, value)
        case .language:
            return try AccessibilityChecker.fix(document, .setLanguage, value)
        case .none:
            if row.action != .setTabOrder { return false }
            return try AccessibilityChecker.fix(document, .setTabOrder)
        }
    }

    /// What the title box starts with: the file's title, else its name.
    public static func titleOf(_ document: PdfDocument, _ fileName: String) -> String {
        let title = DocumentMetadata.read(document).title ?? ""
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (fileName as NSString).deletingPathExtension : title
    }

    /// What the language box starts with: the file's language, else the one the person speaks.
    public static func languageOf(_ document: PdfDocument) -> String {
        let language = PdfText.read(document, document.catalog, "Lang") ?? ""
        return language.isEmpty ? Locale.preferredLanguages.first ?? "en" : language
    }

    /// Whether tags can be added: the file has neither the tagged mark nor a tree, which is what the tagger needs.
    public static func canAddTags(_ document: PdfDocument) -> Bool {
        !document.isTagged && document.dict(document.catalog, "StructTreeRoot") == nil
    }

    /// Writes the description of a figure; an empty one removes it.
    public static func setAlt(_ document: PdfDocument, _ tree: StructureTree, _ figure: StructElement, _ text: String) throws {
        let alt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        figure.alt = alt.isEmpty ? nil : alt
        try tree.write(document)
    }
}
