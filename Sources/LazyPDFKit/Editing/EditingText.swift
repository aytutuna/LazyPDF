import Foundation

// Twin of windows/LazyPDF.Core/Editing/EditingText.cs: the words of the problems the editor reports.

public enum EditingText {
    public static var noFont: String { L10n.t("No font has these letters.") }
    /// The C# property holds the format and callers fill in the letters with string.Format.
    public static func noGlyphs(_ letters: String) -> String { L10n.t("No font has {0}.", letters) }
    public static var fontSetOutside: String { L10n.t("The font is set outside this form.") }
    public static var colorOutside: String { L10n.t("The colour is set outside this form.") }
    public static var sharedForm: String { L10n.t("The same form is painted twice.") }
    public static var vertical: String { L10n.t("Vertical text cannot be changed.") }
    public static var actualText: String { L10n.t("This text has replacement text.") }
    public static var noText: String { L10n.t("There is no text there.") }
    public static var unbalanced: String { L10n.t("The graphics state is left open around it.") }
    public static var crossesLines: String { L10n.t("The match runs over two lines.") }
    public static var noImage: String { L10n.t("This picture cannot be read.") }
    public static var clipPath: String { L10n.t("A path that clips cannot be changed.") }
    public static var notAlone: String { L10n.t("It shares its group with other content.") }
    public static var tooBig: String { L10n.t("The area is empty.") }
    public static var moreStreams: String { L10n.t("The text is in more than one stream.") }
    public static var mixedSizes: String { L10n.t("The block is set in more than one size.") }
    public static var nothingChanged: String { L10n.t("Nothing to change.") }
    public static var stateBetween: String { L10n.t("A setting between them would change it.") }
    public static var alreadyThere: String { L10n.t("It is already there.") }
    public static var staleObject: String { L10n.t("The object is from before the last change.") }
}
