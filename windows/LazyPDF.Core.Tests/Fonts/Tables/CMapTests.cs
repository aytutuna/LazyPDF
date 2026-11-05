using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class CMapTests
{
    static byte[] Bytes(string s) => Encoding.ASCII.GetBytes(s);

    const string Header = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Test def /CMapType 2 def\n";

    [Fact]
    public void ReadsBfCharAndBfRange()
    {
        var map = CMap.Parse(Bytes(Header + """
            1 begincodespacerange <00> <FF> endcodespacerange
            2 beginbfchar <01> <0041> <02> <00660069> endbfchar
            2 beginbfrange <10> <12> <0061> <20> <21> [<0058> <005900590059>] endbfrange
            endcmap
            """));
        Assert.Equal("Test", map.Name);
        Assert.Equal("A", map.UnicodeOf(1));
        Assert.Equal("fi", map.UnicodeOf(2));
        Assert.Equal("a", map.UnicodeOf(0x10));
        Assert.Equal("c", map.UnicodeOf(0x12));
        Assert.Equal("X", map.UnicodeOf(0x20));
        Assert.Equal("YYY", map.UnicodeOf(0x21));
        Assert.Null(map.UnicodeOf(0x13));
        Assert.Null(map.UnicodeOf(0x22));
    }

    [Fact]
    public void SurrogatePairsAndTwoByteCodes()
    {
        var map = CMap.Parse(Bytes(Header + """
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            1 beginbfchar <0003> <D83DDE00> endbfchar
            1 beginbfrange <0100> <0102> <D83DDE00> endbfrange
            """));
        Assert.Equal("\U0001F600", map.UnicodeOf(3));
        Assert.Equal("\U0001F601", map.UnicodeOf(0x101));
        Assert.Equal(0x0102, map.NextCode([0x01, 0x02, 0x03], out int length));
        Assert.Equal(2, length);
    }

    [Fact]
    public void BfCharMayNameAGlyph()
    {
        var map = CMap.Parse(Bytes(Header + "1 beginbfchar <05> /fi endbfchar"));
        Assert.Equal("ﬁ", map.UnicodeOf(5));
    }

    [Fact]
    public void ToleratesCommentsStringsAndOddSpacing()
    {
        var map = CMap.Parse(Bytes("%!PS-Adobe\n/CIDSystemInfo << /Registry (Ado)be) /Ordering (UCS) >> def\n"
            + "1 begincodespacerange<00><FF>endcodespacerange 1 beginbfchar % c\n<41>\n<00 42>endbfchar"));
        Assert.Equal("B", map.UnicodeOf(0x41));
    }

    [Fact]
    public void ReadsCidMappingsAndNotdef()
    {
        var map = CMap.Parse(Bytes(Header + """
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            1 beginnotdefrange <0000> <001F> 1 endnotdefrange
            2 begincidrange <0020> <007E> 100 <8000> <80FF> 500 endcidrange
            1 begincidchar <0100> 7 endcidchar
            """));
        Assert.Equal(100, map.CidOf(0x20));
        Assert.Equal(100 + 0x41 - 0x20, map.CidOf(0x41));
        Assert.Equal(500 + 0xFF, map.CidOf(0x80FF));
        Assert.Equal(7, map.CidOf(0x100));
        Assert.Equal(1, map.CidOf(0x05));
        Assert.Null(map.CidOf(0x200));
    }

    [Fact]
    public void MixedLengthCodespaces()
    {
        var map = CMap.Parse(Bytes(Header + """
            4 begincodespacerange <00> <80> <8140> <9FFC> <A0> <DF> <E040> <FCFC> endcodespacerange
            """));
        var s = new byte[] { 0x41, 0x82, 0xA0, 0xB1, 0xE0, 0x40 };
        int pos = 0;
        var seen = new List<(int Code, int Length)>();
        while (pos < s.Length)
        {
            int code = map.NextCode(s.AsSpan(pos), out int length);
            seen.Add((code, length));
            pos += length;
        }
        Assert.Equal([(0x41, 1), (0x82A0, 2), (0xB1, 1), (0xE040, 2)], seen);
    }

    [Fact]
    public void InvalidBytesStayInStep()
    {
        var map = CMap.Parse(Bytes(Header + "2 begincodespacerange <00> <80> <8140> <9FFC> endcodespacerange"));
        Assert.Equal(0x8120, map.NextCode([0x81, 0x20, 0x41], out int length));
        Assert.Equal(2, length);
        Assert.Equal(0xFF, map.NextCode([0xFF, 0x41], out length));
        Assert.Equal(1, length);
        map.NextCode([0x81], out length);
        Assert.Equal(1, length);
        map.NextCode([], out length);
        Assert.Equal(0, length);
    }

    [Fact]
    public void WithoutACodespaceTheMappingLengthsDecide()
    {
        var map = CMap.Parse(Bytes(Header + "1 beginbfchar <0041> <0041> endbfchar"));
        Assert.Equal(0x0041, map.NextCode([0x00, 0x41, 0x00], out int length));
        Assert.Equal(2, length);
    }

    [Fact]
    public void CodesOfDifferentLengthsAreDifferentCodes()
    {
        var map = CMap.Parse(Bytes(Header + """
            2 begincodespacerange <00> <7F> <8000> <FFFF> endcodespacerange
            1 begincidchar <41> 1 endcidchar
            1 begincidchar <0041> 2 endcidchar
            """));
        Assert.Equal(1, map.CidOf(0x41, 1));
        Assert.Equal(2, map.CidOf(0x41, 2));
        Assert.Equal(1, map.CidOf(0x41));
    }

    [Fact]
    public void LaterMappingsWinOverEarlierOnes()
    {
        var map = CMap.Parse(Bytes(Header + "2 begincidrange <00> <FF> 0 <10> <1F> 900 endcidrange"));
        Assert.Equal(905, map.CidOf(0x15));
        Assert.Equal(0x30, map.CidOf(0x30));
    }

    [Fact]
    public void UseCMapTakesTheParentsMappingsAndCodespace()
    {
        var map = CMap.Parse(Bytes(Header + "/90ms-RKSJ-H usecmap 1 begincidchar <82A0> 9999 endcidchar"));
        Assert.Equal(9999, map.CidOf(0x82A0));
        Assert.Equal(231 + 0x41 - 0x20, map.CidOf(0x41));
        map.NextCode([0x82, 0xA0], out int length);
        Assert.Equal(2, length);
    }

    [Fact]
    public void UseCMapFromTheStreamDictionary()
    {
        var parent = CMap.Parse(Bytes(Header + "1 begincodespacerange <00> <FF> endcodespacerange 1 begincidchar <41> 5 endcidchar"));
        var child = CMap.Parse(Bytes(Header + "1 begincidchar <42> 6 endcidchar"), parent);
        Assert.Equal(5, child.CidOf(0x41));
        Assert.Equal(6, child.CidOf(0x42));
    }

    [Fact]
    public void UnknownUseCMapIsIgnored()
    {
        var map = CMap.Parse(Bytes(Header + "/No-Such-CMap usecmap 1 begincidchar <0041> 5 endcidchar"));
        Assert.Equal(5, map.CidOf(0x41));
        Assert.Null(map.CidOf(0x42));
    }

    [Fact]
    public void ReadsWritingMode()
    {
        Assert.True(CMap.Parse(Bytes(Header + "/WMode 1 def")).IsVertical);
        Assert.False(CMap.Parse(Bytes(Header + "/WMode 0 def")).IsVertical);
    }

    [Fact]
    public void IdentityMaps()
    {
        var h = CMap.Predefined("Identity-H");
        Assert.False(h.IsVertical);
        Assert.True(CMap.Predefined("Identity-V").IsVertical);
        Assert.Equal(0x1234, h.NextCode([0x12, 0x34, 0x56], out int length));
        Assert.Equal(2, length);
        Assert.Equal(0x1234, h.CidOf(0x1234));
        Assert.Equal(0, h.CidOf(0));
        Assert.Null(h.CidOf(0x10000));
        Assert.Null(h.UnicodeOf(0x41));
        Assert.False(h.IsFallback);
    }

    [Fact]
    public void ShiftJisPredefined()
    {
        var map = CMap.Predefined("90ms-RKSJ-H");
        Assert.Equal(843, map.CidOf(0x82A0));
        Assert.Equal(2, ReadLength(map, [0x82, 0xA0]));
        Assert.Equal(1, ReadLength(map, [0x41, 0x82, 0xA0]));
        Assert.Same(map, CMap.Predefined("90ms-RKSJ-H"));
        Assert.True(CMap.Predefined("90ms-RKSJ-V").IsVertical);
    }

    [Fact]
    public void UnicodePredefinedCMapsMapCodesToCidsAndText()
    {
        var map = CMap.Predefined("UniJIS-UCS2-H");
        Assert.Equal(843, map.CidOf(0x3042));
        Assert.Equal("あ", map.UnicodeOf(0x3042));
        var v = CMap.Predefined("UniJIS-UTF16-V");
        Assert.True(v.IsVertical);
        Assert.Equal(CMap.Predefined("UniJIS-UTF16-H").CidOf(0x3042), v.CidOf(0x3042));
        Assert.Equal("\U00020B9F", CMap.Predefined("UniJIS-UTF16-H").UnicodeOf(unchecked((int)0xD842DF9F)));
    }

    [Theory]
    [InlineData("GBK-EUC-H")]
    [InlineData("UniGB-UCS2-H")]
    [InlineData("B5pc-H")]
    [InlineData("ETen-B5-V")]
    [InlineData("UniCNS-UTF16-H")]
    [InlineData("KSC-EUC-H")]
    [InlineData("KSCms-UHC-H")]
    [InlineData("UniKS-UCS2-V")]
    [InlineData("EUC-H")]
    [InlineData("H")]
    [InlineData("V")]
    public void CjkPredefinedCMapsLoad(string name)
    {
        var map = CMap.Predefined(name);
        Assert.False(map.IsFallback);
        Assert.Equal(name, map.Name);
        map.NextCode([0x41, 0x42], out int length);
        Assert.InRange(length, 1, 2);
    }

    [Fact]
    public void UnknownPredefinedNameIsTwoByteCodes()
    {
        var map = CMap.Predefined("Adobe-Japan1-UCS2");
        Assert.True(map.IsFallback);
        Assert.Equal(0x3042, map.NextCode([0x30, 0x42], out int length));
        Assert.Equal(2, length);
        Assert.Equal(0x3042, map.CidOf(0x3042));
    }

    [Fact]
    public void GarbageGivesAnEmptyMap()
    {
        foreach (var junk in new[] { "", "\0\0\0", "<<<<>>>>", "((((", "begincidrange <", "1 begincidrange <00> endcidrange",
                     "begincodespacerange <0000000000> <FF> endcodespacerange", "beginbfrange <00> <10> [ <41>" })
        {
            var map = CMap.Parse(Bytes(junk));
            Assert.Null(map.CidOf(0x41));
            Assert.Null(map.UnicodeOf(0x41));
            map.NextCode([1, 2, 3], out int length);
            Assert.InRange(length, 1, 3);
        }
    }

    [Fact]
    public void ReversedAndOversizedRangesAreSkipped()
    {
        var map = CMap.Parse(Bytes(Header + """
            1 begincodespacerange <0000> <FFFF> endcodespacerange
            1 begincidrange <0010> <0001> 5 endcidrange
            1 beginbfrange <0000> <FFFF> <0000> endbfrange
            """));
        Assert.Null(map.CidOf(5));
        Assert.Equal("A", map.UnicodeOf(0x41));
        Assert.Equal("￿", map.UnicodeOf(0xFFFF));
    }

    [Fact]
    public void RandomBytesNeverThrow()
    {
        var rng = new Random(7);
        var words = new[] { "begincidrange", "endcidrange", "beginbfrange", "beginbfchar", "begincodespacerange", "/usecmap", "usecmap", "[", "]", "<", ">", "<41>", "<0041> <0043> 12", "(", "%", "/WMode", "99999999999999999999", "-5" };
        for (int round = 0; round < 300; round++)
        {
            var sb = new StringBuilder();
            for (int i = 0; i < 200; i++)
                sb.Append(rng.Next(3) == 0 ? ((char)rng.Next(256)).ToString() : words[rng.Next(words.Length)]).Append(' ');
            var map = CMap.Parse(Encoding.Latin1.GetBytes(sb.ToString()));
            map.NextCode(new byte[] { 0x41, 0x42, 0x43, 0x44, 0x45 }, out int length);
            Assert.InRange(length, 1, 4);
            map.CidOf(0x41);
            map.UnicodeOf(0x41);
        }
    }

    [Fact]
    public void HostileInputIsBounded()
    {
        var sb = new StringBuilder(Header + "1 begincodespacerange <00> <FF> endcodespacerange\n");
        for (int i = 0; i < 200_000; i++)
            sb.Append("1 beginbfrange <00> <FF> <0041> endbfrange\n");
        sb.Append("1 beginbfchar <00> <").Append(new string('A', 2_000_000)).Append("> endbfchar\n");
        sb.Append(new string('<', 100_000)).Append(new string('(', 100_000));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var map = CMap.Parse(Encoding.ASCII.GetBytes(sb.ToString()));
        Assert.True(watch.ElapsedMilliseconds < 5000, $"{watch.ElapsedMilliseconds} ms");
        Assert.Equal(new string('ꪪ', 128), map.UnicodeOf(0x00));
    }

    [Fact]
    public void ManyEntriesAreCapped()
    {
        var sb = new StringBuilder("1 begincodespacerange <0000> <FFFF> endcodespacerange 1 begincidchar\n");
        for (int i = 0; i < 1_200_000; i++)
            sb.Append("<").Append((i & 0xFFFF).ToString("X4")).Append("> ").Append(i).Append('\n');
        sb.Append("endcidchar");
        var map = CMap.Parse(Encoding.ASCII.GetBytes(sb.ToString()));
        Assert.NotNull(map.CidOf(0x10));
        Assert.Equal(1_000_000, map.Cids.Count);
    }

    static string Repeat(string section, string line, int count, string end) =>
        "1 begincodespacerange <00000000> <FFFFFFFF> endcodespacerange\n" + section + "\n" +
        new StringBuilder().Insert(0, line + "\n", count) + end;

    [Fact]
    public void EveryKindOfEntryStopsAtTheCap()
    {
        var chars = CMap.Parse(Bytes(Repeat("begincidchar", "<00000001> 5", 1_200_000, "endcidchar")));
        Assert.Equal(1_000_000, chars.Cids.Count);
        var ranges = CMap.Parse(Bytes(Repeat("begincidrange", "<00000001> <00000002> 5", 1_200_000, "endcidrange")));
        Assert.Equal(1_000_000, ranges.Cids.Count);
        var bfChars = CMap.Parse(Bytes(Repeat("beginbfchar", "<00000001> <0041>", 1_200_000, "endbfchar")));
        Assert.Equal(1_000_000, bfChars.Texts.Count);
        var bfRanges = CMap.Parse(Bytes(Repeat("beginbfrange", "<00000001> <00000002> <0041>", 1_200_000, "endbfrange")));
        Assert.Equal(1_000_000, bfRanges.Texts.Count);
        var bfArray = CMap.Parse(Bytes(Repeat("beginbfrange\n<00000000> <FFFFFFFF> [", "<0041>", 1_200_000, "] endbfrange")));
        Assert.Equal(1_000_000, bfArray.Texts.Count);
    }

    [Fact]
    public void TheCapCountsNotdefsAndCidsTogether()
    {
        string text = Repeat("beginnotdefchar", "<00000001> 5", 600_000, "endnotdefchar") + "\n1 begincidchar\n" +
            new StringBuilder().Insert(0, "<00000002> 7\n", 600_000) + "endcidchar";
        var map = CMap.Parse(Bytes(text));
        Assert.Equal(600_000, map.Notdefs.Count);
        Assert.Equal(400_000, map.Cids.Count);
    }

    [Fact]
    public void CodespacesAreCappedAt100()
    {
        var sb = new StringBuilder();
        for (int i = 0; i < 2; i++)
        {
            sb.Append("60 begincodespacerange\n");
            for (int j = 0; j < 60; j++)
                sb.Append("<00> <FF>\n");
            sb.Append("endcodespacerange\n");
        }
        Assert.Equal(100, CMap.Parse(Bytes(sb.ToString())).SpaceList.Count);
    }

    [Fact]
    public void FourByteCodesWrapWhereTheyOverflow()
    {
        var ranges = CMap.Parse(Bytes("1 begincidrange <00000000> <7FFFFFFF> 2147483647 endcidrange"));
        Assert.Equal(int.MinValue, ranges.CidOf(1, 4));
        Assert.Equal(int.MaxValue, ranges.CidOf(0, 4));

        var high = CMap.Parse(Bytes("1 begincodespacerange <00000000> <FFFFFFFF> endcodespacerange 2 beginbfchar <80000000> <0041> <FFFFFFFF> <0042> endbfchar"));
        Assert.Equal(int.MinValue, high.NextCode([0x80, 0x00, 0x00, 0x00], out int length));
        Assert.Equal(4, length);
        Assert.Equal("A", high.UnicodeOf(int.MinValue, 4));
        Assert.Equal(-1, high.NextCode([0xFF, 0xFF, 0xFF, 0xFF], out _));
        Assert.Equal("B", high.UnicodeOf(-1, 4));
    }

    [Fact]
    public void ABfRangeArrayPastTheLastCodeWraps()
    {
        var map = CMap.Parse(Bytes("1 beginbfrange <FFFFFFFE> <FFFFFFFF> [<0041> <0042> <0043>] endbfrange"));
        Assert.Equal("A", map.UnicodeOf(-2, 4));
        Assert.Equal("B", map.UnicodeOf(-1, 4));
        Assert.Equal("C", map.UnicodeOf(0, 4));
    }

    static int ReadLength(CMap map, byte[] bytes)
    {
        map.NextCode(bytes, out int length);
        return length;
    }

    [Fact]
    public void UnknownNamesGiveAFallbackThatIsNotKept()
    {
        var first = CMap.Predefined("No-Such-CMap-H");
        Assert.True(first.IsFallback);
        Assert.NotSame(first, CMap.Predefined("No-Such-CMap-H"));
        Assert.Same(CMap.Predefined("Identity-H"), CMap.Predefined("Identity-H"));
    }
}
