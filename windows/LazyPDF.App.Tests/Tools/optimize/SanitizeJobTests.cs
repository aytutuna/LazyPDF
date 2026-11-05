using LazyPDF.App.Tools.Optimize;
using LazyPDF.App.Tools.Sanitize;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Clean for sharing: the rows a scan makes, the options the ticks stand for and a run on a real file.
public sealed class SanitizeJobTests
{
    private static byte[] Titled()
    {
        var session = PdfEditSession.Open(Pdfs.Text(2));
        Pdfs.Retitle(session, "Salary review");
        session.Commit("Title");
        return session.Current.ToArray();
    }

    private static HashSet<SanitizeItem> All => [.. Enum.GetValues<SanitizeItem>()];

    [Fact]
    public void TheScanFindsTheTitleAsMetadata()
    {
        var findings = SanitizeJob.Scan(Titled(), null, null);

        Assert.Contains(findings, f => f.Item == SanitizeItem.Metadata);
    }

    [Fact]
    public void OnlyTheRemovableItemsCanBeSwitchedAndInvisibleTextStartsOff()
    {
        var rows = Enum.GetValues<SanitizeItem>().ToDictionary(i => i, i => new SanitizeRow(new SanitizeFinding(i, 1)));

        Assert.True(rows[SanitizeItem.Comments].CanTick);
        Assert.True(rows[SanitizeItem.Comments].IsChecked);
        Assert.False(rows[SanitizeItem.HiddenText].CanTick);
        Assert.False(rows[SanitizeItem.HiddenText].IsChecked);
        Assert.False(rows[SanitizeItem.PreviousVersions].CanTick);
        Assert.True(rows[SanitizeItem.PreviousVersions].IsChecked);
        Assert.True(rows[SanitizeItem.InvisibleText].CanTick);
        Assert.False(rows[SanitizeItem.InvisibleText].IsChecked);
    }

    [Fact]
    public void TheTicksBecomeOptions()
    {
        var options = SanitizeJob.Options(new HashSet<SanitizeItem> { SanitizeItem.Comments, SanitizeItem.InvisibleText });

        Assert.True(options.Comments);
        Assert.True(options.InvisibleText);
        Assert.False(options.JavaScript);
        Assert.False(options.Metadata);
    }

    [Fact]
    public void ARunTakesOutWhatWasTickedAndSaysSo()
    {
        var result = SanitizeJob.Run(Titled(), null, null, All, CancellationToken.None);

        Assert.Contains(result.Removed, f => f.Item == SanitizeItem.Metadata);
        Assert.Contains(OptimizeText.ItemName(SanitizeItem.Metadata), SanitizeJob.List(result.Removed));
        using var reopened = PdfDocument.Open(result.Bytes);
        Assert.Equal(2, reopened.Pages.Count);
        Assert.NotEqual("Salary review", DocumentMetadata.Read(reopened).Title);
    }

    [Fact]
    public void AnItemLeftUntickedStaysInTheFile()
    {
        var ticked = All;
        ticked.Remove(SanitizeItem.Metadata);

        var result = SanitizeJob.Run(Titled(), null, null, ticked, CancellationToken.None);

        Assert.Contains(result.Kept, f => f.Item == SanitizeItem.Metadata);
        using var reopened = PdfDocument.Open(result.Bytes);
        Assert.Equal("Salary review", DocumentMetadata.Read(reopened).Title);
    }
}
