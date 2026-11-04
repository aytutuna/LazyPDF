using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ContentParserTests
{
    private static IReadOnlyList<ContentOperation> Parse(string text) => ContentTestPdf.Parse(text);

    [Fact]
    public void OperandsGoWithTheirOperator()
    {
        var ops = Parse("q 1 0 0 1 10 20 cm /F1 12 Tf (Hi) Tj Q");
        Assert.Equal(["q", "cm", "Tf", "Tj", "Q"], ops.Select(o => o.Operator));
        Assert.Equal(6, ops[1].Operands.Count);
        Assert.Equal(20, ops[1].Number(5));
        Assert.Equal("F1", ((PdfName)ops[2].Operands[0]).Value);
        Assert.Equal("Hi", Encoding.Latin1.GetString(((PdfString)ops[3].Operands[0]).Bytes));
    }

    [Fact]
    public void PositionsCoverOperandsAndOperator()
    {
        string text = "q  10 20 m % comment\n 30 40 l S Q";
        var ops = Parse(text);
        Assert.Equal("10 20 m", text[ops[1].Start..ops[1].End]);
        Assert.Equal("30 40 l", text[ops[2].Start..ops[2].End]);
        Assert.Equal("S", text[ops[3].Start..ops[3].End]);
    }

    [Theory]
    [InlineData("--5 w", "-5")]
    [InlineData("-.5 w", "-.5")]
    [InlineData("4. w", "4.")]
    [InlineData("+3 w", "+3")]
    [InlineData("- w", "0")]
    [InlineData(". w", "0")]
    public void OddNumbersReadAsAViewerReadsThem(string content, string text)
    {
        var op = Parse(content)[0];
        Assert.Equal("w", op.Operator);
        Assert.Equal(text, ((PdfNumber)op.Operands[0]).Text);
    }

    [Fact]
    public void JoinedNumbersSplit()
    {
        var ops = Parse("1.2.3 5-3 m");
        Assert.Equal(["1.2", ".3", "5", "-3"], ops[0].Operands.Select(o => ((PdfNumber)o).Text));
    }

    [Fact]
    public void StringsEscapesAndHex()
    {
        var ops = Parse("(a\\(b\\)\\101\\n\\\nc(nested)) Tj <48656C6C6F2> Tj");
        Assert.Equal("a(b)A\nc(nested)", Encoding.Latin1.GetString(((PdfString)ops[0].Operands[0]).Bytes));
        var hex = (PdfString)ops[1].Operands[0];
        Assert.True(hex.IsHex);
        Assert.Equal("Hello ", Encoding.Latin1.GetString(hex.Bytes));
    }

    [Fact]
    public void NamesDecodeEscapes()
    {
        var op = Parse("/A#20B gs")[0];
        Assert.Equal("A B", ((PdfName)op.Operands[0]).Value);
    }

    [Fact]
    public void ArraysAndDictionariesNest()
    {
        var ops = Parse("[(A) -120 (B) [1 2]] TJ /OC <</MCID 3 /K [/A <</X 1>>]>> BDC");
        var array = (PdfArray)ops[0].Operands[0];
        Assert.Equal(4, array.Items.Count);
        var dictionary = (PdfDictionary)ops[1].Operands[1];
        Assert.Equal(3, ((PdfNumber)dictionary["MCID"]!).Value);
    }

    [Fact]
    public void BooleansAndNullAreOperands()
    {
        var op = Parse("true false null foo")[0];
        Assert.Equal("foo", op.Operator);
        Assert.Equal(3, op.Operands.Count);
    }

    [Fact]
    public void UnknownOperatorsStayAndClearOperands()
    {
        var ops = Parse("1 2 3 zork 4 w");
        Assert.Equal(["zork", "w"], ops.Select(o => o.Operator));
        Assert.Single(ops[1].Operands);
    }

    [Fact]
    public void StrayDelimitersAreSkipped()
    {
        var ops = Parse(") ] >> } 1 w >");
        Assert.Single(ops);
        Assert.Equal("w", ops[0].Operator);
    }

    [Fact]
    public void AnUnclosedArrayEndsAtTheNextOperator()
    {
        var ops = Parse("BT [(A) 10 (B) TJ ET");
        Assert.Equal(["BT", "TJ", "ET"], ops.Select(o => o.Operator));
        Assert.Equal(3, ((PdfArray)ops[1].Operands[0]).Items.Count);
    }

    [Fact]
    public void AnUnclosedStringOrHexRunsToTheEnd()
    {
        Assert.Empty(Parse("(never closed Tj"));
        Assert.Empty(Parse("<4142 Tj"));
    }

    [Fact]
    public void DeepNestingIsCut()
    {
        string deep = new string('[', 100000) + "1 w";
        Assert.NotNull(ContentTestPdf.Parse(deep));
    }

    [Fact]
    public void TooManyOperandsAreDropped()
    {
        var ops = Parse(string.Join(' ', Enumerable.Repeat("1", 5000)) + " w");
        Assert.True(ops[0].Operands.Count <= 512);
    }

    [Fact]
    public void BinaryJunkDoesNotThrow()
    {
        var random = new Random(7);
        for (int round = 0; round < 50; round++)
        {
            var bytes = new byte[2000];
            random.NextBytes(bytes);
            _ = ContentParser.Parse(bytes);
        }
    }

    [Fact]
    public void InlineImageWithUnfilteredDataUsesItsLength()
    {
        // The data holds "EI" in the middle, as raw samples may.
        byte[] data = [0x00, (byte)' ', (byte)'E', (byte)'I', (byte)' ', 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0];
        var bytes = ContentTestPdf.Latin("q BI /W 4 /H 3 /BPC 8 /CS /G ID ").Concat(data).Concat(ContentTestPdf.Latin("\nEI Q")).ToArray();
        var ops = ContentParser.Parse(bytes);
        Assert.Equal(["q", "BI", "Q"], ops.Select(o => o.Operator));
        Assert.Equal(data, ops[1].Image!.Data);
        Assert.Equal(4, ((PdfNumber)ops[1].Image!.Dictionary["W"]!).Value);
    }

    [Fact]
    public void InlineImageWithAFilterFindsEiByWhatFollows()
    {
        // Binary data with a stray " EI " followed by non-text bytes, then the real end.
        byte[] data = [1, 2, 3, (byte)' ', (byte)'E', (byte)'I', (byte)' ', 0xFF, 0xFE, 0xFD, 9, 8, 7];
        var bytes = ContentTestPdf.Latin("BI /W 2 /H 2 /F /Fl /CS /RGB /BPC 8 ID\n").Concat(data).Concat(ContentTestPdf.Latin("\nEI\n1 w")).ToArray();
        var ops = ContentParser.Parse(bytes);
        Assert.Equal(["BI", "w"], ops.Select(o => o.Operator));
        Assert.Equal(data, ops[0].Image!.Data);
    }

    [Fact]
    public void InlineImageEndsAtTheEndOfDataWithoutEi()
    {
        var ops = Parse("BI /W 1 /H 1 /F /AHx ID 00>");
        Assert.Single(ops);
        Assert.Equal("BI", ops[0].Operator);
    }

    [Fact]
    public void InlineImageWithCrLfAfterId()
    {
        var bytes = ContentTestPdf.Latin("BI /W 1 /H 1 /BPC 8 /CS /G ID\r\n").Concat(new byte[] { 7 }).Concat(ContentTestPdf.Latin("\nEI")).ToArray();
        var ops = ContentParser.Parse(bytes);
        Assert.Equal(new byte[] { 7 }, ops[0].Image!.Data);
    }

    [Fact]
    public void ExpandedInlineDictionaryUsesFullKeys()
    {
        var image = Parse("BI /W 1 /H 1 /BPC 8 /CS /Cs1 /F /Fl ID x\nEI")[0].Image!;
        var expanded = image.Expanded(name => new PdfName("DeviceRGB"));
        Assert.NotNull(expanded["Width"]);
        Assert.NotNull(expanded["Filter"]);
        Assert.Equal("DeviceRGB", ((PdfName)expanded["ColorSpace"]!).Value);
    }

    [Fact]
    public void LargeStreamParsesQuickly()
    {
        var sb = new StringBuilder();
        for (int i = 0; i < 200000; i++) sb.Append("BT /F1 10 Tf 1 0 0 1 10 20 Tm (Hello) Tj ET\n");
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var ops = ContentTestPdf.Parse(sb.ToString());
        Assert.Equal(1_000_000, ops.Count);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), watch.Elapsed.ToString());
    }
}
