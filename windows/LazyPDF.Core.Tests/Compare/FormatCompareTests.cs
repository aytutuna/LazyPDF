using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.CompareKit;

namespace LazyPDF.Core.Tests;

public class FormatCompareTests
{
    private const string Middle = "Second line is where the format changes now";

    private static CompareLine[][] Page3(CompareLine middle) =>
    [[
        new("First line of the page stays plain and the same"),
        middle,
        new("Third line also stays exactly as it was before"),
    ]];

    private static ComparisonResult Run(CompareLine[][] before, CompareLine[][] after)
    {
        using var a = Doc(before);
        using var b = Doc(after);
        return PdfComparer.Compare(a, b);
    }

    [Fact]
    public void FontChangeOnlyIsOneFormatChangeAndNoTextChange()
    {
        var result = Run(Page3(new(Middle)), Page3(new(Middle, "F2")));
        var change = Assert.Single(result.Changes);
        Assert.Equal((ChangeKind.Changed, ChangeArea.Format), (change.Kind, change.Area));
        Assert.Equal(Middle, change.OldText);
        Assert.Equal(Middle, change.NewText);
        Assert.Contains("Helvetica", change.Detail);
        Assert.Contains("Times", change.Detail);
        Assert.Single(change.OldQuads);
        Assert.Single(change.NewQuads);
        Assert.Equal(1, result.Summary.Format);
        Assert.Equal(0, result.Summary.Text);
    }

    [Fact]
    public void SizeChangeIsFormatOnly()
    {
        var change = Assert.Single(Run(Page3(new(Middle)), Page3(new(Middle, Size: 14))).Changes);
        Assert.Equal(ChangeArea.Format, change.Area);
        Assert.Contains("12", change.Detail);
        Assert.Contains("14", change.Detail);
    }

    [Fact]
    public void ColourChangeIsFormatOnly()
    {
        var change = Assert.Single(Run(Page3(new(Middle)), Page3(new(Middle, Color: "1 0 0"))).Changes);
        Assert.Equal(ChangeArea.Format, change.Area);
        Assert.Contains("#FF0000", change.Detail);
    }

    [Fact]
    public void OneWordInAnotherFontIsJustThatWord()
    {
        CompareLine[][] before = [[new("alpha beta gamma delta epsilon zeta eta theta iota kappa")]];
        string file = TestPdf.Text(Bytes(before)).Replace(
            "(alpha beta gamma delta epsilon zeta eta theta iota kappa) Tj",
            "(alpha beta gamma delta ) Tj /F3 12 Tf (epsilon) Tj /F1 12 Tf ( zeta eta theta iota kappa) Tj");
        using var a = Doc(before);
        using var b = Open(TestPdf.Latin(file));
        var change = Assert.Single(PdfComparer.Compare(a, b).Changes);
        Assert.Equal(ChangeArea.Format, change.Area);
        Assert.Equal("epsilon", change.OldText);
    }

    [Fact]
    public void FormatAndTextChangesAreReportedSeparately()
    {
        var result = Run(Page3(new(Middle)), Page3(new("Second line is where the layout changes now", "F2")));
        Assert.Equal(1, result.Summary.Text);
        Assert.Equal(2, result.Summary.Format);
        Assert.Equal("format", result.Changes.Single(c => c.Area == ChangeArea.Text).OldText);
    }

    [Fact]
    public void SubsetTagOfTheSameFontIsNotAChange()
    {
        var pdf = Bytes(Page3(new(Middle)));
        string tagged = TestPdf.Text(pdf).Replace("/BaseFont /Helvetica ", "/BaseFont /ABCDEF+Helvetica ");
        using var a = Open(pdf);
        using var b = Open(TestPdf.Latin(tagged));
        Assert.True(PdfComparer.Compare(a, b).IsIdentical);
    }
}
