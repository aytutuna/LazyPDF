import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionText.cs: the texts redaction raises to the user.

public enum RedactionText {
    public static var noFont: String { L10n.t("No font for this text. Pick another font.") }
    public static var nothingFound: String { L10n.t("Nothing was under the marks.") }
    public static let replacedBy = "[redacted]"
    public static var textElsewhere: String { L10n.t("Descriptions, links and names") }
    public static var xmpUnreadable: String { L10n.t("An XMP packet that could not be read") }

    public static func line(_ p: PageRedaction) -> String {
        var parts: [String] = []
        if p.glyphs > 0 { parts.append(L10n.plural(p.glyphs, one: "{0} character", other: "{0} characters")) }
        if p.images > 0 { parts.append(L10n.plural(p.images, one: "{0} picture", other: "{0} pictures")) }
        if p.paths > 0 { parts.append(L10n.plural(p.paths, one: "{0} shape", other: "{0} shapes")) }
        if p.annotations > 0 { parts.append(L10n.plural(p.annotations, one: "{0} note", other: "{0} notes")) }
        if p.fields > 0 { parts.append(L10n.plural(p.fields, one: "{0} form field", other: "{0} form fields")) }
        return L10n.t("Page {0}: removed {1}.", p.page + 1, parts.joined(separator: ", "))
    }

    public static func needsPicture(_ page: Int) -> String {
        L10n.t("Page {0} cannot be redacted as text. It needs a page renderer to be turned into a picture.", page + 1)
    }

    public static func notDrawn(_ page: Int) -> String {
        L10n.t("Page {0} could not be drawn, so it cannot be turned into a picture.", page + 1)
    }

    public static func flattened(_ page: Int) -> String {
        L10n.t("Page {0} was turned into a picture. Its text can no longer be selected.", page + 1)
    }

    public static func metadataHolds(_ place: String) -> String { L10n.t("{0} holds removed text.", place) }
    public static func metadataChanged(_ place: String) -> String { L10n.t("{0} held removed text. It was replaced.", place) }

    public static func signaturesGone(_ count: Int) -> String {
        L10n.plural(count, one: "The signature is gone.", other: "{0} signatures are gone.")
    }

    public static func removed(_ text: String) -> String { L10n.t("Removed: {0}", text) }

    public static func stillInside(_ page: Int) -> String { L10n.t("Text is still inside a mark on page {0}.", page + 1) }
    public static func pageOf(_ page: Int) -> String { L10n.t("page {0}|in a sentence", page + 1) }
    public static func attachedFile(_ number: Int) -> String { L10n.t("an attached file (object {0})", number) }
    public static func notChecked(_ place: String) -> String { L10n.t("{0} could not be opened, so it was not checked.", place) }
    public static func stillInFile(_ place: String) -> String { L10n.t("Removed text is still in {0}.", place) }

    public static func notFollowed(_ page: Int) -> String {
        L10n.t("Page {0} could not be followed to its end, so it was not fully checked.", page + 1)
    }

    public static var tooManyStrings: String { L10n.t("Not every removed string could be checked.") }
    public static var doesNotOpen: String { L10n.t("The output does not open.") }
}
