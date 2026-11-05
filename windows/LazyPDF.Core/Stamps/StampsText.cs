namespace LazyPDF.Core;

/// <summary>Texts the stamps raise to the user.</summary>
public static class StampsText
{
    public static string NoFont => Loc.T("No font for this text. Pick another font.");
    public static string PictureTooLarge => Loc.T("That picture is too large. Pick a smaller one.");
    public static string NeedsContent => Loc.T("Give the stamp a text or a picture.");
}
