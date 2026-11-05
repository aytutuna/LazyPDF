using LazyPDF.App.Tools.Optimize;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Make smaller: the audit rows, the options each choice stands for and a run on real files.
public sealed class OptimizeJobTests
{
    private static readonly OptimizeChoice Balanced = new(SizePreset.Balanced, CustomSize.Default, false, false);

    [Fact]
    public void TheAuditListsTheBiggestKindFirstAndAddsUpToTheFile()
    {
        var audit = OptimizeJob.Audit(Pdfs.Text(5), null, null);

        var rows = AuditRow.Of(audit);

        Assert.NotEmpty(rows);
        Assert.All(rows, r => Assert.True(r.Bytes > 0));
        Assert.Equal(rows.OrderByDescending(r => r.Bytes), rows);
        Assert.Equal(1.0, rows.Sum(r => r.Share), 6);
    }

    [Fact]
    public void ThePresetsGiveTheCoreOnes()
    {
        Assert.Equal(96, new OptimizeChoice(SizePreset.Small, CustomSize.Default, false, false).Options(null).ImageDpi);
        Assert.Equal(150, Balanced.Options(null).ImageDpi);
        Assert.Equal(300, new OptimizeChoice(SizePreset.High, CustomSize.Default, false, false).Options(null).ImageDpi);
    }

    [Fact]
    public void CustomSettingsAndGrayscaleReachTheOptions()
    {
        var custom = new CustomSize(200, 60, false, false, false, true);

        var options = new OptimizeChoice(SizePreset.Custom, custom, true, false).Options(null);

        Assert.Equal(200, options.ImageDpi);
        Assert.Equal(300, options.ImageDpiAbove);
        Assert.Equal(60, options.JpegQuality);
        Assert.Equal(-1, options.BilevelTolerance);
        Assert.False(options.SubsetFonts);
        Assert.False(options.StripPieceInfo);
        Assert.True(options.StripPrivateData);
        Assert.True(options.Grayscale);
    }

    [Fact]
    public void ARunGivesAFileThatReopensWithTheSamePages()
    {
        var outcome = OptimizeJob.Run(Pdfs.Text(3), null, null, Balanced, new FakeCodec(), CancellationToken.None);

        using var reopened = PdfDocument.Open(outcome.Bytes);
        Assert.Equal(3, reopened.Pages.Count);
        Assert.Equal(outcome.Bytes.Length, outcome.Result.SizeAfter);
        Assert.False(reopened.IsLinearized);
    }

    [Fact]
    public void FastWebViewLinearizesTheResult()
    {
        var choice = Balanced with { FastWebView = true };

        var outcome = OptimizeJob.Run(Pdfs.Text(3), null, null, choice, new FakeCodec(), CancellationToken.None);

        using var reopened = PdfDocument.Open(outcome.Bytes);
        Assert.True(reopened.IsLinearized);
        Assert.Equal(3, reopened.Pages.Count);
        Assert.Equal(outcome.Bytes.Length, outcome.Result.SizeAfter);
    }

    [Fact]
    public void APasswordFileComesOutLocked()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var security = PdfSecurity.Create("open", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, document.FirstId ?? []);
        byte[] locked = document.SaveRewrite(new PdfSaveOptions(Security: security));

        var outcome = OptimizeJob.Run(locked, "owner", null, Balanced with { FastWebView = true }, new FakeCodec(), CancellationToken.None);

        Assert.Throws<PdfReadException>(() => PdfDocument.Open(outcome.Bytes));
        using var reopened = PdfDocument.Open(outcome.Bytes, "open");
        Assert.True(reopened.IsEncrypted);
    }

    [Fact]
    public void ACancelledRunGivesNothing()
    {
        using var source = new CancellationTokenSource();
        source.Cancel();

        Assert.Throws<OperationCanceledException>(() => OptimizeJob.Run(Pdfs.Text(), null, null, Balanced, new FakeCodec(), source.Token));
    }

    [Theory]
    [InlineData(1000L, 250L, 75)]
    [InlineData(1000L, 1000L, 0)]
    [InlineData(0L, 0L, 0)]
    public void ThePercentSavedIsRounded(long before, long after, int percent) =>
        Assert.Equal(percent, SizeText.Percent(before, after));

    [Fact]
    public void AnAes128FileKeepsTheIdItsKeysCameFrom()
    {
        byte[] id = [.. Enumerable.Range(1, 16).Select(i => (byte)i)];
        using var source = PdfDocument.Open(Pdfs.Text());
        var security = PdfSecurity.Create("open", "owner", PdfPermissions.All, PdfCryptStrength.Aes128, id);
        byte[] locked = source.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id));

        foreach (bool web in new[] { false, true })
        {
            var outcome = OptimizeJob.Run(locked, "open", null, Balanced with { FastWebView = web }, new FakeCodec(), CancellationToken.None);

            using var reopened = PdfDocument.Open(outcome.Bytes, "open");
            Assert.True(reopened.IsEncrypted);
            using var asOwner = PdfDocument.Open(outcome.Bytes, "owner");
            Assert.Single(asOwner.Pages);
        }
    }

    [Fact]
    public void AFileThatRestrictsItsPermissionsNeedsTheOwner()
    {
        using var restricted = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print));
        using var open = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print), "owner");
        using var plain = PdfDocument.Open(Pdfs.Text());

        Assert.True(OptimizeJob.NeedsOwner(restricted));
        Assert.False(OptimizeJob.NeedsOwner(open));
        Assert.False(OptimizeJob.NeedsOwner(plain));
    }
}
