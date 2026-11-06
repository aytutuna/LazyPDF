import Foundation

// Twin of windows/LazyPDF.Core/Ocr/OcrStatusText.cs: the texts the OCR action raises to the user.

public enum OcrStatusText {
    public static var label: String { L10n.t("Make searchable") }
    public static var nothing: String { L10n.t("No pages need text recognition.") }

    public static func status(_ page: Int, _ total: Int) -> String {
        L10n.t("Reading page {0} of {1}", page, total)
    }

    public static func statusFull(_ page: Int, _ total: Int) -> String {
        L10n.t("Recognizing the text on page {0} of {1}.", page, total)
    }
}
