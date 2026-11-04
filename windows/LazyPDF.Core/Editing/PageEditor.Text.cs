namespace LazyPDF.Core;

public sealed partial class PageEditor
{
    /// <summary>
    /// Replaces the characters of a range of <see cref="Text"/> (a word, a line, a selection) with
    /// <paramref name="text"/>, in the same font, size, colour and spacing and on the same baseline.
    /// Characters the font cannot show come from a matching font of the editor's
    /// <see cref="IFontSource"/>, reported in the result. Text after the range in the same run moves
    /// with it; text in other runs stays where it is.
    /// </summary>
    public TextEditResult ReplaceText(TextRange range, string text) =>
        EditText("Edit text", editor => editor.Replace(range, text));

    /// <summary>Takes the text out of a range; what follows in the same run keeps its place.</summary>
    public TextEditResult DeleteText(TextRange range) => EditText("Delete text", editor => editor.Delete(range));

    /// <summary>Adds text before the character <paramref name="index"/>, in the font of the glyph it goes next to.</summary>
    public TextEditResult InsertText(int index, string text) => EditText("Insert text", editor => editor.Insert(index, text));

    /// <summary>
    /// Replaces the text of a block: the lines are laid out again inside the width the block had
    /// (a single line stays one line), with the alignment the block shows. Lines the new text does
    /// not need are removed; extra lines are added below, over whatever is there, and the result
    /// says the block <see cref="TextEditResult.Grew"/>. The block takes the style of its first glyph.
    /// </summary>
    public TextEditResult ReplaceParagraph(TextObject block, string text) =>
        EditText("Edit paragraph", editor => editor.Paragraph(block, text));

    /// <summary>Changes the look of the text of the ranges; see <see cref="TextStyleChange"/>.</summary>
    public TextEditResult SetTextStyle(IEnumerable<TextRange> ranges, TextStyleChange change) =>
        EditText("Format text", editor =>
        {
            foreach (var range in ranges) editor.Restyle(range, change);
        });

    /// <summary>Moves the lines of a block to the left edge, the right edge or the middle of the block, or spreads them over its width.</summary>
    public TextEditResult SetAlignment(TextObject block, TextAlignment alignment) =>
        EditText("Align text", editor => editor.Align(block, alignment));

    /// <summary>Sets the distance between baselines of a block, moving each line from the first by a text rise.</summary>
    public TextEditResult SetLineSpacing(TextObject block, double spacing) =>
        EditText("Line spacing", editor => editor.Space(block, spacing));
}
