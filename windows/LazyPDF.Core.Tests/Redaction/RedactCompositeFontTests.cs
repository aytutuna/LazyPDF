using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactCompositeFontTests
{
    // Arial embedded as a Type0 font with two-byte codes, drawing the text as hex strings.
    private static PdfDocument Embedded(string text, Func<byte[], string> content)
    {
        var document = RedactionKit.Page("");
        var font = new PdfFontEmbedder(document, new ArialSource()).Add("Arial", FontStyles.Regular, [text], embed: true)!;
        Assert.True(font.IsEmbedded);
        var page = document.Pages[0];
        var fonts = document.Dict(ContentResources.ForEdit(document, page), "Font")!;
        fonts["F2"] = font.Reference;
        page.Dictionary["Contents"] = document.Add(new PdfStream(new PdfDictionary(), System.Text.Encoding.Latin1.GetBytes(content(font.Encode(text)))));
        return document;
    }

    [Fact]
    public void ACodeNeverEndsInTheMiddleOfAnotherAndTheRestStays()
    {
        const string text = "Hello SECRETWORD there";
        using var document = Embedded(text, bytes => $"BT /F2 14 Tf 50 700 Td <{Convert.ToHexString(bytes)}> Tj ET");
        var before = RedactionKit.Glyphs(document);
        Assert.Equal(text, RedactionKit.Text(before));
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "SECRETWORD"));
        using var output = RedactionKit.Open(result);
        var after = RedactionKit.Glyphs(output);
        Assert.Equal("Hello  there", RedactionKit.Text(after));
        var expected = before.Take(6).Concat(before.Skip(16)).ToList();
        for (int i = 0; i < expected.Count; i++)
        {
            Assert.Equal(expected[i].X, after[i].X, 0.01);
            Assert.Equal(expected[i].Y, after[i].Y, 0.01);
        }
        Assert.False(RedactionKit.Holds(result.Bytes, "SECRETWORD"));
    }

    [Fact]
    public void KerningBetweenTwoByteStringsIsKept()
    {
        const string text = "ab SECRET cd";
        using var document = Embedded(text, bytes =>
        {
            string hex = Convert.ToHexString(bytes);
            return $"BT /F2 14 Tf 50 700 Td [<{hex[..12]}> -300 <{hex[12..]}>] TJ ET";
        });
        var before = RedactionKit.Glyphs(document);
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "SECRET"));
        using var output = RedactionKit.Open(result);
        var after = RedactionKit.Glyphs(output);
        Assert.Equal("ab  cd", RedactionKit.Text(after));
        Assert.Equal(before[^1].X, after[^1].X, 0.01);
    }
}
