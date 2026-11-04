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
}
