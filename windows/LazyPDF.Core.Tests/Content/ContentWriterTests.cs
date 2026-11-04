using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ContentWriterTests
{
    private static string Text(ContentWriter w) => Encoding.Latin1.GetString(w.ToArray());

    private static string Describe(IReadOnlyList<ContentOperation> ops) =>
        string.Join("|", ops.Select(o => o.Operator + ":" + string.Join(",", o.Operands.Select(x => x.ToString())) + (o.Image is { } i ? "#" + Convert.ToHexString(i.Data) : "")));

    [Theory]
    [InlineData("q 1 0 0 1 10 20.5 cm /F1 12 Tf (a\\(b\\)\\n) Tj <00FF> Tj [(A) -120 (B)] TJ Q")]
    [InlineData("/Span <</MCID 3 /Lang (en)>> BDC EMC [3 2] 1 d 0.5 g 0 0 100 100 re f*")]
    [InlineData("BT 1 0 0 1 5 5 Tm (x) ' 1 2 (y) \" ET")]
    [InlineData("1 2 zork 3 4 w true false null foo")]
    public void ParseThenWriteGivesTheSameOperations(string content)
    {
        var first = ContentTestPdf.Parse(content);
        var second = ContentParser.Parse(ContentWriter.Write(first));
        Assert.Equal(Describe(first), Describe(second));
    }

    [Fact]
    public void InlineImagesSurviveARoundTripEvenWithBinaryData()
    {
        byte[] data = [0, 1, 2, (byte)' ', (byte)'E', (byte)'I', (byte)' ', 0xFF, 0xFE, 0x80, 10, 13, 40, 41];
        var bytes = ContentTestPdf.Latin("q BI /W 14 /H 1 /BPC 8 /CS /G ID ").Concat(data).Concat(ContentTestPdf.Latin("\nEI Q")).ToArray();
        var first = ContentParser.Parse(bytes);
        var second = ContentParser.Parse(ContentWriter.Write(first));
        Assert.Equal(["q", "BI", "Q"], second.Select(o => o.Operator));
        Assert.Equal(data, second[1].Image!.Data);
    }

    [Fact]
    public void RoundTripOfARealPage()
    {
        var content = ContentTestPdf.Latin(string.Concat(Enumerable.Repeat("BT /F1 10 Tf 1 0 0 1 72 700 Tm [(Hello) -250 (World)] TJ ET\n0.2 0.4 0.6 rg 10 10 50 50 re f\n", 200)));
        var first = ContentParser.Parse(content);
        var second = ContentParser.Parse(ContentWriter.Write(first));
        Assert.Equal(Describe(first), Describe(second));
    }

    [Fact]
    public void NumbersAreShortAndInvariant()
    {
        var w = new ContentWriter().Op("m", 0.1 + 0.2, 1e-9, -0.0, 12345678, 1.5, 2.0 / 3);
        Assert.Equal("0.3 0 0 12345678 1.5 0.666667 m\n", Text(w));
        var previous = Thread.CurrentThread.CurrentCulture;
        try
        {
            Thread.CurrentThread.CurrentCulture = new System.Globalization.CultureInfo("tr-TR");
            Assert.Equal("1.5 0 l\n", Text(new ContentWriter().LineTo(1.5, 0)));
        }
        finally
        {
            Thread.CurrentThread.CurrentCulture = previous;
        }
    }

    [Fact]
    public void HelpersWriteTheOperatorsTheyAreNamedFor()
    {
        var w = new ContentWriter()
            .Save().Concat(new PdfMatrix(1, 0, 0, 1, 10, 20)).FillRgb(1, 0, 0).Rect(0, 0, 50, 40).Fill().Restore()
            .BeginText().Font("F1", 12).MoveText(72, 700).Show("Hi"u8).EndText()
            .Paint("Im1", new PdfMatrix(100, 0, 0, 50, 0, 0))
            .BeginMarked("Span", 7).EndMarked();
        Assert.Equal(
            "q\n1 0 0 1 10 20 cm\n1 0 0 rg\n0 0 50 40 re\nf\nQ\nBT\n/F1 12 Tf\n72 700 Td\n<4869> Tj\nET\nq\n100 0 0 50 0 0 cm\n/Im1 Do\nQ\n/Span <</MCID 7>> BDC\nEMC\n",
            Text(w));
    }

    [Fact]
    public void BuiltContentParsesBackAndRuns()
    {
        var w = new ContentWriter().Save().FillRgb(0, 0, 1).Rect(10, 10, 20, 20).Fill().Restore()
            .BeginText().Font("F1", 10).MoveText(50, 60).Show("AB"u8).EndText();
        var document = ContentTestPdf.Page(w.ToArray(), "/Font <</F1 5 0 R>>", ContentTestPdf.Helvetica);
        var r = ContentTestPdf.Run(document);
        Assert.Equal("AB", r.Text);
        Assert.Equal(new PdfRect(10, 10, 30, 30), r.Paths[0].Path.Bounds);
        Assert.Equal(new RgbColor(0, 0, 255), r.Paths[0].State.FillColor.Rgb);
    }

    [Fact]
    public void RawAddsALine()
    {
        Assert.Equal("1 w\n", Text(new ContentWriter().Raw("1 w")));
    }

    [Fact]
    public void ACutRangeCanBeRemovedByPosition()
    {
        string source = "BT /F1 10 Tf (secret) Tj (keep) Tj ET";
        var ops = ContentTestPdf.Parse(source);
        var target = ops.First(o => o.Operator == "Tj");
        string edited = source[..target.Start] + source[target.End..];
        Assert.Equal("BT /F1 10 Tf  (keep) Tj ET", edited);
    }
}
