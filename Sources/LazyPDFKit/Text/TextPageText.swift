import Foundation

// Twin of windows/LazyPDF.Core/Text/TextPageText.cs: the words of the problems the text layer reports.

public enum TextPageText {
    public static var annotationsIncluded: String {
        L10n.t("This text includes annotation text, which the page's content does not hold. Build the page without IncludeAnnotations to edit or redact it.")
    }
}
