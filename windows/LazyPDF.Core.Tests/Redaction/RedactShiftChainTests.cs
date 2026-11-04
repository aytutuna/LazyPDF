using System.Text.RegularExpressions;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// What stays of the positions between removed shows: a matrix or text matrix per show, or a size per show, gives the width of each removed letter.
public class RedactShiftChainTests
{
    private static readonly PdfRect Letters = new(95, 90, 140, 120);

    private static int Count(string content, string op) => Regex.Matches(content, $@"(?<![\w*]){Regex.Escape(op)}(?![\w*])").Count;

    [Fact]
    public void ChainOfMatricesBetweenRemovedShowsBecomesOne()
    {
        string line(string letter, string move) => $"{move} cm BT /F1 12 Tf 100 100 Td ({letter}) Tj ET ";
        using var document = RedactionKit.Page(line("Z", "1 0 0 1 6 0") + line("Q", "1 0 0 1 6.67 0") + line("X", "1 0 0 1 6.67 0") + "BT /F1 12 Tf 100 300 Td (kept) Tj ET");
        double before = RedactionKit.Glyphs(document).First(g => Math.Abs(g.Y - 300) < 0.01).X;
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Letters)]);
        using var output = RedactionKit.Open(result);
        Assert.Equal(1, Count(RedactionKit.Latin(output), "cm"));
        Assert.Equal(before, RedactionKit.Glyphs(output).First(g => Math.Abs(g.Y - 300) < 0.01).X, 0.01);
    }

    [Fact]
    public void TextMatrixPerRemovedShowInsideASavedStateIsDropped()
    {
        string line(string letter, string x) => $"q BT /F1 12 Tf 1 0 0 1 {x} 100 Tm ({letter}) Tj ET Q ";
        using var document = RedactionKit.Page(line("Z", "106") + line("Q", "112.67") + line("X", "119.34") + "BT /F1 12 Tf 1 0 0 1 300 400 Tm (kept) Tj ET");
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Letters)]);
        using var output = RedactionKit.Open(result);
        Assert.Equal(1, Count(RedactionKit.Latin(output), "Tm"));
        Assert.Equal(300, RedactionKit.Glyphs(output).First().X, 0.01);
    }

    [Fact]
    public void ShiftOfARemovedShowMovesToTheNextOneWhateverItsSize()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 100 Td (Z) Tj /F1 12.01 Tf (Q) Tj /F1 12 Tf (X) Tj /F1 12.01 Tf (C) Tj /F1 12 Tf (kept) Tj ET");
        double before = RedactionKit.Glyphs(document).Last().X;
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXC"));
        using var output = RedactionKit.Open(result);
        Assert.Equal(1, Count(RedactionKit.Latin(output), "TJ"));
        Assert.Equal(before, RedactionKit.Glyphs(output).Last().X, 0.05);
    }
}
