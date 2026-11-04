using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class VerticalTextTests
{
    private const string ToUnicode =
        "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /X def /CMapType 2 def " +
        "1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfrange <0041> <005A> <0041> endbfrange endcmap end end";

    private static PdfEditSession Open(string encoding) =>
        PdfEditSession.Open(EditKit.File("BT /F3 12 Tf 100 700 Td <004100420043> Tj ET", more: pdf =>
        {
            pdf.Obj(7, $"<</Type /Font /Subtype /Type0 /BaseFont /Arial /Encoding /{encoding} /DescendantFonts [<</Type /Font /Subtype /CIDFontType2 /BaseFont /Arial " +
                "/CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 600>>] /ToUnicode 8 0 R>>");
            pdf.Stream(8, "", ToUnicode);
        }, resources: "/Font <</F1 5 0 R /F3 7 0 R>>"));

    [Fact]
    public void VerticalTextIsLeftAlone()
    {
        var session = Open("Identity-V");
        var editor = new PageEditor(session, 0);
        Assert.Equal("ABC", editor.Text.Text.Trim());
        var result = editor.ReplaceText(new TextRange(0, 3), "XYZ");
        Assert.False(result.Done);
        Assert.Equal(EditingText.Vertical, result.Problem);
        Assert.False(session.CanUndo);
    }

    [Fact]
    public void HorizontalCidTextWithoutAnEmbeddedProgramTakesLettersItsMapShows()
    {
        var session = Open("Identity-H");
        var editor = new PageEditor(session, 0);
        var result = editor.ReplaceText(new TextRange(0, 3), "CAB");
        Assert.True(result.Done, result.Problem);
        Assert.Equal("CAB", EditKit.Text(session).Trim());
        // A letter the map does not cover has no code in this font and no source to come from.
        var refused = new PageEditor(session, 0).ReplaceText(new TextRange(0, 3), "abc");
        Assert.False(refused.Done);
        Assert.Equal(EditingText.NoFont, refused.Problem);
    }
}
