namespace LazyPDF.Core;

/// <summary>The words of the problems the editor reports.</summary>
public static class EditingText
{
    public static string NoFont => Loc.T("No font has these letters.");
    public static string NoGlyphs => Loc.T("No font has {0}.");
    public static string FontSetOutside => Loc.T("The font is set outside this form.");
    public static string ColorOutside => Loc.T("The color is set outside this form.");
    public static string SharedForm => Loc.T("The same form is painted twice.");
    public static string Vertical => Loc.T("Vertical text cannot be changed.");
    public static string ActualText => Loc.T("This text has replacement text.");
    public static string NoText => Loc.T("There is no text there.");
    public static string Unbalanced => Loc.T("The graphics state is left open around it.");
    public static string CrossesLines => Loc.T("The match runs over two lines.");
    public static string NoImage => Loc.T("This picture cannot be read.");
    public static string ClipPath => Loc.T("A path that clips cannot be changed.");
    public static string NotAlone => Loc.T("It shares its group with other content.");
    public static string TooBig => Loc.T("The area is empty.");
    public static string MoreStreams => Loc.T("The text is in more than one stream.");
    public static string MixedSizes => Loc.T("The block is set in more than one size.");
    public static string NothingChanged => Loc.T("Nothing to change.");
    public static string StateBetween => Loc.T("A setting between them would change it.");
    public static string AlreadyThere => Loc.T("It is already there.");
    public static string StaleObject => Loc.T("The object is from before the last change.");
}
