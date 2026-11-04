using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class LinearizerUpdateTests
{
    private static byte[] Linear(int pages = 5) => PdfDocument.Open(LinearizerKit.Make(pages)).SaveLinearized();

    [Fact]
    public void AnUpdateLeavesAValidFileThatIsNoLongerLinearized()
    {
        byte[] file = Linear();
        using var document = PdfDocument.Open(file);
        Assert.True(document.IsLinearized);

        document.Info!["Title"] = new PdfString(Encoding.Latin1.GetBytes("Changed"), isHex: false);
        byte[] updated = document.SaveIncremental();

        Assert.True(updated.AsSpan(0, file.Length).SequenceEqual(file));
        using var again = PdfDocument.Open(updated);
        Assert.False(again.IsLinearized);
        Assert.True(again.WasLinearized);
        Assert.Equal(5, again.Pages.Count);
        Assert.Equal("Changed", SaveFixtures.Title(again));
        Assert.Empty(again.Repairs);
        Assert.Equal(LinearizerKit.PigText(file), LinearizerKit.PigText(updated));
    }

    [Fact]
    public void ASessionCommitDoesTheSame()
    {
        var session = PdfEditSession.Open(Linear(3));
        Assert.True(session.Document.IsLinearized);
        session.Document.Info!["Title"] = new PdfString(Encoding.Latin1.GetBytes("Committed"), isHex: false);
        Assert.True(session.Commit("title"));

        Assert.False(session.Document.IsLinearized);
        Assert.True(session.Undo());
        Assert.True(session.Document.IsLinearized);
    }

    [Fact]
    public void AFileCutShortIsNotLinearized()
    {
        byte[] file = Linear();
        using var document = PdfDocument.Open(file[..^20]);

        Assert.False(document.IsLinearized);
        Assert.Equal(5, document.Pages.Count);
    }

    [Fact]
    public void AWrongLengthIsNotLinearized()
    {
        byte[] file = Linear();
        string text = Encoding.Latin1.GetString(file);
        int at = text.IndexOf("/L ", StringComparison.Ordinal) + 3;
        file[at + 3] ^= 1;

        using var document = PdfDocument.Open(file);
        Assert.False(document.IsLinearized);
    }

    [Fact]
    public void ADictionaryWithoutALengthIsNotLinearized()
    {
        byte[] file = Linear();
        int at = Encoding.Latin1.GetString(file).IndexOf("/L ", StringComparison.Ordinal);
        file[at + 1] = (byte)'X';

        using var document = PdfDocument.Open(file);
        Assert.False(document.IsLinearized);
    }

    [Fact]
    public void AnOrdinaryFileIsNotLinearized()
    {
        using var document = PdfDocument.Open(LinearizerKit.Make(2));

        Assert.False(document.IsLinearized);
    }

    [Fact]
    public void BytesBeforeTheHeaderAreCutAndTheLengthStillMatches()
    {
        byte[] file = Linear(2);
        using var document = PdfDocument.Open([.. "junk\n"u8.ToArray(), .. file]);

        Assert.True(document.IsLinearized);
    }
}
