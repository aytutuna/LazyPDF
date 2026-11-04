namespace LazyPDF.Core;

/// <summary>The words of the problems the editor reports.</summary>
public static class EditingText
{
    public const string NoFont = "No font has these letters.";
    public const string NoGlyphs = "No font has {0}.";
    public const string FontSetOutside = "The font is set outside this form.";
    public const string ColorOutside = "The colour is set outside this form.";
    public const string SharedForm = "The same form is painted twice.";
    public const string Vertical = "Vertical text cannot be changed.";
    public const string ActualText = "This text has replacement text.";
    public const string NoText = "There is no text there.";
    public const string Unbalanced = "The graphics state is left open around it.";
    public const string CrossesLines = "The match runs over two lines.";
    public const string NoImage = "This picture cannot be read.";
    public const string ClipPath = "A path that clips cannot be changed.";
    public const string NotAlone = "It shares its group with other content.";
    public const string TooBig = "The area is empty.";
    public const string MoreStreams = "The text is in more than one stream.";
    public const string MixedSizes = "The block is set in more than one size.";
    public const string NothingChanged = "Nothing to change.";
    public const string StateBetween = "A setting between them would change it.";
    public const string AlreadyThere = "It is already there.";
    public const string StaleObject = "The object is from before the last change.";
}
