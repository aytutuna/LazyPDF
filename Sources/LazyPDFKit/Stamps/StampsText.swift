import Foundation

// Twin of windows/LazyPDF.Core/Stamps/StampsText.cs: the texts the stamps raise to the user.

public enum StampsText {
    public static var noFont: String { L10n.t("No font for this text. Pick another font.") }
    public static var pictureTooLarge: String { L10n.t("That picture is too large. Pick a smaller one.") }
    public static var needsContent: String { L10n.t("Give the stamp a text or a picture.") }
}
