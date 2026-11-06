import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportText.cs: the few words the export writes into its files and that a person
// may read.

public enum ExportText {
    public static func page(_ number: Int) -> String { L10n.t("Page {0}", number) }
    public static func image(_ number: Int) -> String { L10n.t("Picture {0}", number) }
    public static func table(_ number: Int, _ page: Int) -> String { L10n.t("Table {0} (p{1})", number, page) }
    public static func slide(_ number: Int) -> String { L10n.t("Slide {0}", number) }

    public static var noUsablePicture: String { L10n.t("None of the pictures could be read.") }
    public static var tooLarge: String { L10n.t("The file is too large to export.") }

    public static func picturesLeftOut(_ count: Int) -> String {
        L10n.plural(count, one: "{0} picture was left out because the file is too large.", other: "{0} pictures were left out because the file is too large.")
    }

    public static var noFont: String { L10n.t("No font file can draw this text.") }
}
