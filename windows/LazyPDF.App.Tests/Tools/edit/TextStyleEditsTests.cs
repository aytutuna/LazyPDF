using LazyPDF.App.Documents;
using LazyPDF.App.Tools.EditContent;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Edit;

// Restyling a block through the panel's calls, on files whose text is placed the way real ones place it.
public sealed class TextStyleEditsTests
{
    private static DocumentTab Open(byte[] bytes) => new(PdfEditSession.Open(bytes), new FakeRenderer(), null, "t.pdf");

    private static PageEdits Edits(DocumentTab tab) => new(tab, new FakeFonts(), new FakeCodec());

    private static TextObject Block(DocumentTab tab) => Assert.IsType<TextObject>(new PageEditor(tab.Session, 0).Objects[0]);

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void AFontChangeKeepsTheLinesOfTheBlock(bool bold, bool italic)
    {
        using var tab = Open(EditPdf.Make(EditPdf.Paragraph));
        var before = Block(tab);

        var outcome = Edits(tab).Style(0, before.Id, new TextStyleChange(Bold: bold ? true : null, Italic: italic ? true : null));

        Assert.True(outcome.Done, outcome.Problem);
        var after = Block(tab);
        Assert.Equal(3, after.Lines.Count);
        Assert.Equal(before.Lines.Select(l => l.Text), after.Lines.Select(l => l.Text));
        Assert.True(after.Bounds.Right < 612);
        Assert.Equal(before.Lines[2].Bounds.Bottom, after.Lines[2].Bounds.Bottom, 1);
    }

    [Fact]
    public void ASizeIsTakenInPageUnitsWhateverScalesTheText()
    {
        using var tab = Open(EditPdf.Make("BT /F1 1 Tf 12 0 0 12 50 700 Tm (Scaled text) Tj ET"));
        var block = Block(tab);
        Assert.Equal(12, block.Size, 1);

        var outcome = Edits(tab).Style(0, block.Id, new TextStyleChange(Size: 14));

        Assert.True(outcome.Done, outcome.Problem);
        Assert.Equal(14, Block(tab).Size, 1);
        Assert.Contains("Scaled text", new PageEditor(tab.Session, 0).Text.Text);
    }

    [Fact]
    public void ASizeUnderAScalingCmIsTakenInPageUnits()
    {
        using var tab = Open(EditPdf.Make("q 0.5 0 0 0.5 0 0 cm BT /F1 24 Tf 100 1400 Td (Halved text) Tj ET Q"));
        var block = Block(tab);
        Assert.Equal(12, block.Size, 1);

        Assert.True(Edits(tab).Style(0, block.Id, new TextStyleChange(Size: 8)).Done);

        Assert.Equal(8, Block(tab).Size, 1);
    }

    [Fact]
    public void AColourReachesEveryLine()
    {
        using var tab = Open(EditPdf.Make(EditPdf.Paragraph));

        Assert.True(Edits(tab).Style(0, Block(tab).Id, new TextStyleChange(Color: new RgbColor(200, 30, 30))).Done);

        Assert.Equal(new RgbColor(200, 30, 30), Block(tab).Color);
        Assert.Equal(3, Block(tab).Lines.Count);
    }
}
