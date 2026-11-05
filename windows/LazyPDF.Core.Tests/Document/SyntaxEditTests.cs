using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SyntaxEditTests
{
    [Fact]
    public void LargeDictionaryLooksKeysUpThroughTheIndex()
    {
        var dictionary = new PdfDictionary();
        for (int i = 0; i < 2000; i++) dictionary.Add($"K{i}", new PdfNumber(i));
        Assert.Equal(1234, ((PdfNumber)dictionary["K1234"]!).Integer);
        dictionary["K1234"] = new PdfNumber(-1);
        Assert.Equal(-1, ((PdfNumber)dictionary["K1234"]!).Integer);
        dictionary.Add("K5", new PdfNumber(55));
        Assert.Equal(55, ((PdfNumber)dictionary["K5"]!).Integer);
        Assert.True(dictionary.Remove("K5"));
        Assert.Null(dictionary["K5"]);
        Assert.False(dictionary.ContainsKey("K5"));
        Assert.Equal(1999, dictionary.Count);
        dictionary["New"] = PdfNull.Instance;
        Assert.True(dictionary.ContainsKey("New"));
        dictionary["New"] = null;
        Assert.False(dictionary.ContainsKey("New"));
    }

    [Fact]
    public void WritingAHugeDictionaryIsLinear()
    {
        var dictionary = new PdfDictionary();
        for (int i = 0; i < 200_000; i++) dictionary.Add($"K{i}", new PdfNumber(i));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        string text = dictionary.ToString();
        Assert.StartsWith("<</K0 0 /K1 1", text);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5), $"took {watch.Elapsed}");
    }

    [Fact]
    public void RepeatedKeysWriteOnceWithTheLastValue()
    {
        var dictionary = new PdfDictionary();
        dictionary.Add("A", new PdfNumber(1));
        dictionary.Add("B", new PdfNumber(2));
        dictionary.Add("A", new PdfNumber(3));
        Assert.Equal("<</B 2 /A 3>>", dictionary.ToString());
        Assert.Equal("<<>>", new PdfDictionary().ToString());
    }

    [Fact]
    public void ARealIsWrittenWithoutAnExponent()
    {
        Assert.Equal("0.5", new PdfNumber(0.5).Text);
        Assert.Equal("1", new PdfNumber(1.0).Text);
        Assert.Equal("0", new PdfNumber(-0.0000001).Text);
        Assert.Equal("123456789", new PdfNumber(123456789.0).Text);
        Assert.Equal("-2.333333", new PdfNumber(-7.0 / 3).Text);
        Assert.Equal("7", new PdfNumber(7L).Text);
    }

    [Fact]
    public void StringBytesCanBeReplaced()
    {
        var text = new PdfString(Encoding.Latin1.GetBytes("ab"), isHex: false);
        text.Bytes = [0x41];
        Assert.Equal("(A)", text.ToString());
    }

    [Fact]
    public void RectangleWritesAsAnArray()
    {
        Assert.Equal("[0 0 612 792]", new PdfRect(612, 792, 0, 0).ToArray().ToString());
        Assert.Equal(new PdfRect(0, 0, 5, 5), new PdfRect(0, 0, 10, 10).Intersect(new PdfRect(-5, -5, 5, 5)));
        Assert.True(new PdfRect(0, 0, 1, 1).Intersect(new PdfRect(5, 5, 6, 6)).IsEmpty);
    }

    [Fact]
    public void ANumberKeepsItsTextAndReadsItsValue()
    {
        foreach (var (text, value) in new[] { ("4.", 4.0), ("-.5", -0.5), ("+.5", 0.5), ("0012", 12.0), ("1.25", 1.25) })
        {
            Assert.Equal(value, new PdfNumber(text).Value);
        }
        Assert.Null(new PdfNumber("4.").Integer);
        Assert.Equal(12, new PdfNumber("0012").Integer);
        Assert.Equal(3, new PdfNumber("+3").Integer);
        Assert.Null(new PdfNumber("9223372036854775808").Integer);
    }
}
