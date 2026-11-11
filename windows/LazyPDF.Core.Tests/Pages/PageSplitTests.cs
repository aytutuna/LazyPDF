using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageSplitTests
{
    private static string Order(IEnumerable<PdfDocument> parts) =>
        string.Join(" | ", parts.Select(p => string.Join(",", PageTestFiles.Order(p))));

    [Fact]
    public void EveryNPagesLeavesTheRestInTheLastPart()
    {
        var parts = PageAssembly.SplitEvery(PageTestFiles.Open(5), 2);
        Assert.Equal("1,2 | 3,4 | 5", Order(parts));
        Assert.Equal("1,2,3", Order(PageAssembly.SplitEvery(PageTestFiles.Open(3), 3)));
        Assert.Equal("1 | 2", Order(PageAssembly.SplitEvery(PageTestFiles.Open(2), 1)));
        Assert.Equal("1,2", Order(PageAssembly.SplitEvery(PageTestFiles.Open(2), 10)));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageAssembly.SplitEvery(PageTestFiles.Open(2), 0));
    }

    [Fact]
    public void ByRangesGivesOnePartForEachInTheOrderTyped()
    {
        var document = PageTestFiles.Open(8);
        var ranges = new[] { "1-3", "8, 5", "2-3" }.Select(t => (IReadOnlyList<int>)PageRange.Parse(t, 8).Pages).ToList();
        Assert.Equal("1,2,3 | 8,5 | 2,3", Order(PageAssembly.SplitByRanges(document, ranges)));
        Assert.Throws<ArgumentException>(() => PageAssembly.SplitByRanges(document, [[]]));
    }

    [Fact]
    public void AtPagesStartsAPartAtEachOfThem()
    {
        var document = PageTestFiles.Open(6);
        Assert.Equal("1,2 | 3,4,5 | 6", Order(PageAssembly.SplitAt(document, [2, 5])));
        Assert.Equal("1,2 | 3,4,5 | 6", Order(PageAssembly.SplitAt(document, [5, 0, 2, 2])));
        Assert.Equal("1,2,3,4,5,6", Order(PageAssembly.SplitAt(document, [])));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageAssembly.SplitAt(document, [6]));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageAssembly.SplitAt(document, [-1]));
    }

    [Fact]
    public void EachPartIsAFileOfItsOwn()
    {
        foreach (var part in PageAssembly.SplitEvery(PageTestFiles.Open(5), 2))
        {
            Assert.NotEmpty(PageTestFiles.Reopen(part));
        }
    }

    // Pages of about a kilobyte of data nothing can compress, so that a page weighs what its data does.
    private static PdfDocument Heavy(int count, int perPage) => Weighted(count, i => i == 4 ? perPage * 6 : perPage);

    private static PdfDocument Weighted(int count, Func<int, int> bytes)
    {
        var random = new Random(11);
        byte[] Noise(int n) => [.. Enumerable.Range(0, n).Select(_ => (byte)random.Next(256))];
        var pdf = new TestPdf().Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [{string.Join(" ", Enumerable.Range(0, count).Select(i => $"{3 + i} 0 R"))}] /Count {count} /MediaBox [0 0 100 100]>>");
        for (int i = 0; i < count; i++) pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {3 + count + i} 0 R /Resources <</XObject <</X {3 + 2 * count + i} 0 R>>>>>>");
        for (int i = 0; i < count; i++) pdf.Stream(3 + count + i, "", $"BT ({i + 1}) Tj ET /X Do");
        for (int i = 0; i < count; i++) pdf.Stream(3 + 2 * count + i, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", Noise(bytes(i)));
        return PdfDocument.Open(pdf.Finish());
    }

    private static IEnumerable<int> Numbers(PdfDocument document) =>
        document.Pages.Select(p => int.Parse(Encoding.Latin1.GetString(p.Contents())[4..].Split(')')[0]));

    [Fact]
    public void BySizeFitsAsManyPagesAsTheLimitAllows()
    {
        // Page 5 is six times as heavy as the others: it cannot share a part, and no limit below its size holds it.
        var document = Heavy(12, 1000);
        long one = PageAssembly.Extract(document, [0]).SaveRewrite().Length;
        long three = PageAssembly.Extract(document, [0, 1, 2]).SaveRewrite().Length;
        long limit = three + (three - one) / 2;
        var parts = PageAssembly.SplitBySize(document, limit);
        Assert.Equal(Enumerable.Range(1, 12), parts.SelectMany(Numbers));
        Assert.Equal([3, 1, 1, 3, 3, 1], parts.Select(p => p.Pages.Count));
        Assert.All(parts, p => Assert.True(p.SaveRewrite().Length <= limit || p.Pages.Count == 1));
        Assert.True(parts[2].SaveRewrite().Length > limit);
    }

    // The old search: the longest run from each start that fits, found one page at a time.
    private static string Greedy(PdfDocument document, long limit)
    {
        var parts = new List<string>();
        for (int at = 0; at < document.Pages.Count;)
        {
            int length = 1;
            while (at + length < document.Pages.Count && PageAssembly.Extract(document, [.. Enumerable.Range(at, length + 1)]).SaveRewrite().Length <= limit) length++;
            parts.Add(string.Join(",", Enumerable.Range(at + 1, length)));
            at += length;
        }
        return string.Join(" | ", parts);
    }

    [Fact]
    public void BySizeMakesTheSamePartsAsAScanOnePageAtATime()
    {
        var random = new Random(5);
        var document = Weighted(40, _ => random.Next(100, 3000));
        long whole = document.SaveRewrite().Length;
        foreach (long limit in new[] { whole / 40, whole / 12, whole / 5, whole / 2, whole })
        {
            Assert.Equal(Greedy(document, limit), string.Join(" | ", PageAssembly.SplitBySize(document, limit).Select(p => string.Join(",", Numbers(p)))));
        }
    }

    private sealed class CountingRandom : Random
    {
        public int Calls;
        public override void NextBytes(Span<byte> buffer) { Calls++; base.NextBytes(buffer); }
    }

    [Fact]
    public void BySizeSavesAPartOnlyAFewTimes()
    {
        // With AES each stream written draws random bytes once and a page has two, so the calls tell how many pages were saved.
        var document = Weighted(100, _ => 1000);
        var random = new CountingRandom();
        var options = new PdfSaveOptions(Security: PdfSecurity.Create("", "owner", PdfPermissions.All, PdfCryptStrength.Aes128, new byte[16], random), DocumentId: new byte[16]);
        long one = PageAssembly.Extract(document, [0]).SaveRewrite(options).Length;
        long ten = PageAssembly.Extract(document, [.. Enumerable.Range(0, 10)]).SaveRewrite(options).Length;
        random.Calls = 0;
        var parts = PageAssembly.SplitBySize(document, ten + (ten - one) / 2, options);
        Assert.Equal(100, parts.Sum(p => p.Pages.Count));
        Assert.True(random.Calls <= 2 * 5 * 100, $"{random.Calls / 2} pages saved");
    }

    [Fact]
    public void ALimitOfOneByteGivesOnePagePerPart()
    {
        var parts = PageAssembly.SplitBySize(PageTestFiles.Open(4), 1);
        Assert.Equal(4, parts.Count);
        Assert.Throws<ArgumentOutOfRangeException>(() => PageAssembly.SplitBySize(PageTestFiles.Open(4), 0));
    }

    [Fact]
    public void ACancelledSplitBySizeThrows()
    {
        using var source = new CancellationTokenSource();
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => PageAssembly.SplitBySize(PageTestFiles.Open(6), 1, cancel: source.Token));
    }

    [Fact]
    public void ACancelledSplitByCountThrows()
    {
        using var source = new CancellationTokenSource();
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => PageAssembly.SplitEvery(PageTestFiles.Open(6), 2, source.Token));
    }

    [Fact]
    public void ALimitAboveTheWholeGivesOnePart()
    {
        var parts = PageAssembly.SplitBySize(PageTestFiles.Open(4), 10_000_000);
        Assert.Single(parts);
        Assert.Equal(4, parts[0].Pages.Count);
    }

    [Fact]
    public void ExtractKeepsTheOrderAskedAndTheInfo()
    {
        var document = PdfDocument.Open(PageTestFiles.Make(4, trailerExtra: "/Info 20 0 R", add: pdf => pdf.Obj(20, "<</Title (Kept)>>")));
        var part = PageAssembly.Extract(document, [3, 0, 3]);
        Assert.Equal([4, 1, 4], PageTestFiles.Order(part));
        Assert.Equal("Kept", Encoding.Latin1.GetString(((PdfString)PdfDocument.Open(part.SaveRewrite()).Info!["Title"]!).Bytes));
        Assert.Throws<ArgumentException>(() => PageAssembly.Extract(document, []));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageAssembly.Extract(document, [4]));
    }

    [Fact]
    public void TheSourceIsLeftAsItWas()
    {
        var session = PdfEditSession.Open(PageTestFiles.Make(4));
        PageAssembly.SplitEvery(session.Document, 2);
        PageAssembly.Extract(session.Document, [1]);
        Assert.False(session.Commit("Nothing"));
        Assert.False(session.IsDirty);
    }

    [Fact]
    public void ACountBeyondThePagesIsOnePart()
    {
        Assert.Equal("1,2", Order(PageAssembly.SplitEvery(PageTestFiles.Open(2), int.MaxValue)));
        Assert.Equal("1,2", Order(PageAssembly.SplitEvery(PageTestFiles.Open(2), int.MaxValue - 1)));
    }

    private static PdfDocument WithUnreadableObject() => PageTestFiles.Open(2, pageExtra: _ => "/Thumb 8 0 R", add: pdf => pdf.Obj(8, "<</Broken (never closed"));

    [Fact]
    public void ObjectsThatCannotBeReadAreCountedWhereTheyAreLeftOut()
    {
        Assert.Equal(0, PageAssembly.Extract(PageTestFiles.Open(2), [0, 1]).DroppedObjects);
        Assert.Equal(1, PageAssembly.Extract(WithUnreadableObject(), [0, 1]).DroppedObjects);
        Assert.Equal(1, PageAssembly.Merge([new MergeSource(WithUnreadableObject()), new MergeSource(PageTestFiles.Open(1))]).DroppedObjects);
        Assert.Equal(2, PageAssembly.Merge([new MergeSource(WithUnreadableObject()), new MergeSource(WithUnreadableObject())]).DroppedObjects);
        Assert.All(PageAssembly.SplitEvery(WithUnreadableObject(), 1), p => Assert.Equal(1, p.DroppedObjects));
    }
}
