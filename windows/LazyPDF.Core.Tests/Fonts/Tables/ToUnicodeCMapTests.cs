using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ToUnicodeCMapTests
{
    static string Text(byte[] data) => Encoding.ASCII.GetString(data);

    [Fact]
    public void RoundTripsThroughTheParser()
    {
        var pairs = new Dictionary<int, string>
        {
            [0x0001] = "A", [0x0002] = "B", [0x0003] = "C", [0x0010] = "fi", [0x0020] = "\U0001F600",
            [0x0021] = "\U0001F601", [0x0100] = "þ", [0x0101] = "ÿ", [0x0102] = "Ā", [0xFFFF] = "中",
        };
        var map = CMap.Parse(ToUnicodeCMap.Write(pairs));
        foreach (var (code, text) in pairs)
            Assert.Equal(text, map.UnicodeOf(code));
        Assert.Null(map.UnicodeOf(0x0004));
        Assert.Equal(0x0001, map.NextCode([0x00, 0x01], out int length));
        Assert.Equal(2, length);
    }

    [Fact]
    public void RunsBecomeBfRanges()
    {
        string cmap = Text(ToUnicodeCMap.Write(Enumerable.Range(0, 10).Select(i => KeyValuePair.Create(0x20 + i, ((char)('a' + i)).ToString()))));
        Assert.Contains("1 beginbfrange\n<0020> <0029> <0061>\nendbfrange", cmap);
        Assert.DoesNotContain("beginbfchar", cmap);
    }

    [Fact]
    public void RangesDoNotCrossALowByteWrap()
    {
        var pairs = Enumerable.Range(0xFE, 4).Select(i => KeyValuePair.Create(i, ((char)i).ToString())).ToList();
        var map = CMap.Parse(ToUnicodeCMap.Write(pairs));
        foreach (var (code, text) in pairs)
            Assert.Equal(text, map.UnicodeOf(code));
        Assert.DoesNotContain("<00FE> <0101>", Text(ToUnicodeCMap.Write(pairs)));
    }

    [Fact]
    public void SectionsHoldAtMost100Entries()
    {
        var pairs = Enumerable.Range(0, 250).Select(i => KeyValuePair.Create(i * 2, "x" + (char)(0x4E00 + i * 3)));
        string cmap = Text(ToUnicodeCMap.Write(pairs));
        Assert.Contains("100 beginbfchar", cmap);
        Assert.Contains("50 beginbfchar", cmap);
        var map = CMap.Parse(Encoding.ASCII.GetBytes(cmap));
        Assert.Equal("x" + (char)(0x4E00 + 249 * 3), map.UnicodeOf(498));
    }

    [Fact]
    public void LastTextForACodeWinsAndEmptyTextIsLeftOut()
    {
        var map = CMap.Parse(ToUnicodeCMap.Write([KeyValuePair.Create(5, "a"), KeyValuePair.Create(5, "b"), KeyValuePair.Create(6, "")]));
        Assert.Equal("b", map.UnicodeOf(5));
        Assert.Null(map.UnicodeOf(6));
    }

    [Fact]
    public void OneByteCodes()
    {
        var data = ToUnicodeCMap.Write([KeyValuePair.Create(0x41, "Z")], 1);
        Assert.Contains("<00> <FF>", Text(data));
        var map = CMap.Parse(data);
        Assert.Equal("Z", map.UnicodeOf(0x41));
        map.NextCode([0x41, 0x42], out int length);
        Assert.Equal(1, length);
    }

    [Fact]
    public void HasTheFixedFrame()
    {
        string cmap = Text(ToUnicodeCMap.Write([]));
        Assert.StartsWith("/CIDInit /ProcSet findresource begin", cmap);
        Assert.Contains("begincmap", cmap);
        Assert.Contains("1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange", cmap);
        Assert.EndsWith("end\nend\n", cmap);
    }

    [Fact]
    public void RejectsWhatDoesNotFit()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ToUnicodeCMap.Write([KeyValuePair.Create(0x10000, "a")]));
        Assert.Throws<ArgumentOutOfRangeException>(() => ToUnicodeCMap.Write([KeyValuePair.Create(-1, "a")]));
        Assert.Throws<ArgumentOutOfRangeException>(() => ToUnicodeCMap.Write([], 5));
    }
}
