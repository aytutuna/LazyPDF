using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.CompareKit;

namespace LazyPDF.Core.Tests;

public class AttachmentLimitTests
{
    private const int Mib = 1 << 20;

    private static PdfDocument With(params (string Name, byte[] Data)[] files)
    {
        using var document = Doc(Page("files"));
        foreach (var (name, data) in files) PdfAttachments.Add(document, name, data);
        return Open(document.SaveRewrite());
    }

    [Fact]
    public void FileOverTheSizeCapIsJudgedByItsStoredBytes()
    {
        byte[] big = new byte[65 * Mib];
        byte[] other = (byte[])big.Clone();
        other[^1] = 1;
        using var before = With(("big.bin", big));
        using var same = With(("big.bin", big));
        using var after = With(("big.bin", other));
        Assert.True(PdfComparer.Compare(before, same).IsIdentical);
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Contains("bytes stored", change.OldText);
    }

    [Fact]
    public void UnfilteredFilesOverTheCapDoNotUseUpTheBudget()
    {
        byte[] random = new byte[65 * Mib];
        new Random(7).NextBytes(random);
        byte[] text = System.Text.Encoding.ASCII.GetBytes(string.Concat(Enumerable.Repeat("some text ", 100)));
        using var file = With(("a1.bin", random), ("a2.bin", random), ("a3.bin", random), ("a4.bin", random), ("b.txt", text));
        Assert.True(PdfComparer.Compare(file, file).IsIdentical);
    }

    [Fact]
    public void FileLaterInTheListIsNotChangedByAnEarlierOneBeingRemoved()
    {
        byte[] zeros = new byte[60 * Mib];
        string[] names = ["a.bin", "b.bin", "c.bin", "d.bin", "e.bin"];
        using var before = With([.. names.Select(n => (n, zeros))]);
        using var after = With([.. names.Skip(1).Select(n => (n, zeros))]);
        var change = Assert.Single(PdfComparer.Compare(before, after).Changes);
        Assert.Equal(ChangeKind.Removed, change.Kind);
        Assert.Contains("a.bin", change.Detail);
    }

    private static byte[] Zlib(byte[] data, System.IO.Compression.CompressionLevel level)
    {
        var packed = new MemoryStream();
        using (var z = new System.IO.Compression.ZLibStream(packed, level, true)) z.Write(data);
        return packed.ToArray();
    }

    // Four files that do not decode, each charged the whole cap, then a file whose two sides are packed differently.
    private static PdfDocument WithUndecodable(string word, System.IO.Compression.CompressionLevel level)
    {
        using var document = Doc(Page("files"));
        foreach (string name in new[] { "u1.bin", "u2.bin", "u3.bin", "u4.bin" })
        {
            var added = PdfAttachments.Add(document, name, System.Text.Encoding.ASCII.GetBytes($"{word} {name}"));
            PdfAttachments.StreamOf(document, added)!.Dictionary["Filter"] = new PdfName("NoSuchDecode");
        }
        byte[] text = System.Text.Encoding.ASCII.GetBytes(string.Concat(Enumerable.Repeat("some words to pack ", 200)));
        var last = PdfAttachments.Add(document, "z.txt", text);
        PdfAttachments.StreamOf(document, last)!.Data = Zlib(text, level);
        return Open(document.SaveRewrite());
    }

    [Fact]
    public void FailedDecodesUseUpTheBudget()
    {
        using var before = WithUndecodable("one", System.IO.Compression.CompressionLevel.Optimal);
        using var after = WithUndecodable("uno", System.IO.Compression.CompressionLevel.NoCompression);
        var result = PdfComparer.Compare(before, after);
        var change = Assert.Single(result.Changes, c => c.Detail!.Contains("z.txt"));
        Assert.Contains("bytes stored", change.OldText);
    }

    [Fact]
    public void FilesStoredAlikeCostNoBudget()
    {
        using var before = WithUndecodable("one", System.IO.Compression.CompressionLevel.Optimal);
        using var after = WithUndecodable("one", System.IO.Compression.CompressionLevel.NoCompression);
        Assert.True(PdfComparer.Compare(before, before).IsIdentical);
        Assert.DoesNotContain(PdfComparer.Compare(before, after).Changes, c => c.Detail!.Contains("z.txt"));
    }

    [Fact]
    public void CancelledTokenStopsTheDocumentComparison()
    {
        using var before = With(("a.txt", [1, 2, 3]));
        using var after = With(("a.txt", [1, 2, 4]));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        var comparison = new Comparison(before, after, new CompareOptions(), cancelled.Token);
        Assert.Throws<OperationCanceledException>(() => comparison.CompareDocuments([], []));
    }

    private static PdfDocument SharedBy(int entries)
    {
        using var document = Doc(Page("files"));
        var added = PdfAttachments.Add(document, "r.pdf", [1, 2, 3]);
        var tree = document.Dict(document.Dict(document.Catalog, "Names"), "EmbeddedFiles")!;
        tree["Names"] = new PdfArray([.. Enumerable.Range(0, entries).SelectMany(i => new PdfObject[] { PdfText.ToObject($"k{i:D6}"), added.Spec! })]);
        return Open(document.SaveRewrite());
    }

    [Fact]
    public void ManyEntriesWithOneFileNameAreNamedInLinearTime()
    {
        using var file = SharedBy(20_000);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        Assert.True(PdfComparer.Compare(file, file).IsIdentical);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), watch.Elapsed.ToString());
    }
}
