import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/AccessibilityChecker.Fix.cs: makes the repair an `AccessibilityItem` offers
// and returns whether anything changed. `setTitle` takes the title and `setLanguage` a language tag as `value`; a missing or
// invalid one is an `ArgumentException`. The caller commits the document.

extension AccessibilityChecker {
    public static func fix(_ document: PdfDocument, _ fix: AccessibilityFix, _ value: String? = nil) throws -> Bool {
        switch fix {
        case .setTitle:
            guard let value, !DotNetText.isNullOrWhiteSpace(value) else { throw ArgumentException("A title is needed.") }
            var metadata = DocumentMetadata.read(document)
            metadata.title = DotNetText.trim(value)
            try metadata.write(document)
            _ = showTitle(document)
            return true
        case .showTitle:
            return !DotNetText.isNullOrWhiteSpace(DocumentMetadata.read(document).title) && showTitle(document)
        case .setLanguage:
            guard let value, isLanguageTag(value) else { throw ArgumentException("A language tag such as en-US is needed.") }
            var settings = ViewerSettings.read(document)
            settings.language = value
            settings.write(document)
            return true
        case .setTabOrder:
            var changed = false
            for page in document.pages {
                guard let annots = document.array(page.dictionary, "Annots"), !annots.items.isEmpty,
                      document.name(page.dictionary, "Tabs") != "S" else { continue }
                page.dictionary["Tabs"] = PdfName("S")
                changed = true
            }
            return changed
        case .none:
            return false
        }
    }

    private static func showTitle(_ document: PdfDocument) -> Bool {
        var settings = ViewerSettings.read(document)
        if settings.displayDocTitle { return false }
        settings.displayDocTitle = true
        settings.write(document)
        return true
    }
}
