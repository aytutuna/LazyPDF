using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// The stamp must land where it was asked to whatever state the page leaves behind.
public class UnbalancedPageTests
{
    private const string Page = "BT /F1 12 Tf 50 50 Td (p) Tj ET";

    private static StampGlyph Stamped(string content, Func<PdfStamper, StampRun> stamp, out PdfDocument document)
    {
        document = StampKit.Pages(("", content));
        stamp(new PdfStamper(document));
        return Assert.Single(StampKit.Glyphs(document, 0), g => g.Text == "S");
    }

    private static StampRun Header(PdfStamper s) => s.AddHeaderFooter(new HeaderFooterSpec { Header = new("S", "", "") });

    private static StampRun Mark(PdfStamper s) => s.AddWatermark(new WatermarkSpec { Text = "S", Rotation = 20 });

    public static TheoryData<string> Pages => new()
    {
        "q 2 0 0 2 10 10 cm 0 1 0 rg " + Page,
        "q q q 0.5 0 0 0.5 0 0 cm " + Page,
        "5 0 0 5 0 0 cm " + Page,
        Page + " Q Q Q",
        "BT /F1 12 Tf 50 50 Td (p) Tj",
        "/Span BMC q 3 0 0 3 0 0 cm " + Page,
        "1 0 0 RG 20 w [3] 0 d 0.3 g 0 0 1 rg 4 Tr 9 Tc",
    };

    [Theory]
    [MemberData(nameof(Pages))]
    public void AHeaderLandsWhereItLandsOnACleanPage(string content)
    {
        var clean = Stamped(Page, Header, out _);
        var odd = Stamped(content, Header, out _);
        Assert.Equal((clean.X, clean.Y, clean.Size), (odd.X, odd.Y, odd.Size));
    }

    [Theory]
    [MemberData(nameof(Pages))]
    public void AWatermarkLandsWhereItLandsOnACleanPage(string content)
    {
        var clean = Stamped(Page, Mark, out _);
        var odd = Stamped(content, Mark, out _);
        Assert.Equal((clean.X, clean.Y, clean.Size, clean.DirX), (odd.X, odd.Y, odd.Size, odd.DirX));
    }

    [Fact]
    public void ABehindStampNeedsNoHelpFromThePage()
    {
        var document = StampKit.Pages(("", "q q 4 0 0 4 0 0 cm " + Page));
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "S", Behind = true, Rotation = 0 });
        var clean = StampKit.Doc(1);
        new PdfStamper(clean).AddWatermark(new WatermarkSpec { Text = "S", Behind = true, Rotation = 0 });
        Assert.Equal(StampKit.Glyphs(clean, 0)[0].X, StampKit.Glyphs(document, 0)[0].X, 6);
        Assert.Equal(2, StampKit.ContentStreams(document, 0).Count);
    }

    [Fact]
    public void TheWrapperClosesAsManyAsThePageLeavesOpen()
    {
        var document = StampKit.Pages(("", "q q q BT /Span BMC"));
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "S" });
        var streams = StampKit.ContentStreams(document, 0);
        var close = (PdfStream)document.Resolve(((PdfArray)document.Resolve(document.Pages[0].Dictionary["Contents"])!).Items[^2])!;
        string text = System.Text.Encoding.Latin1.GetString(close.Data!);
        Assert.Equal("ET\nEMC\nQ\nQ\nQ\nQ\n", text);
        Assert.Equal(4, streams.Count);
    }

    [Fact]
    public void ARunawayPageCannotBloatTheWrapper()
    {
        var document = StampKit.Pages(("", string.Concat(Enumerable.Repeat("q ", 50000)) + string.Concat(Enumerable.Repeat("Q ", 70000))));
        new PdfStamper(document).AddWatermark(new WatermarkSpec { Text = "S" });
        var items = ((PdfArray)document.Resolve(document.Pages[0].Dictionary["Contents"])!).Items;
        Assert.All(new[] { items[0], items[^2] }, i => Assert.True(((PdfStream)document.Resolve(i)!).Data!.Length <= 2000 * 2));
    }
}
