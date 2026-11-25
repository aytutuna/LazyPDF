using LazyPDF.App.Tools.Accessibility;
using LazyPDF.App.Tools.Standards;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The PDF/A panel's rows, and the words after a check and a conversion, against Core's validator and converter.
public sealed class PdfARowsTests
{
    [Fact]
    public void IssuesWithTheSameRuleAndSentenceMakeOneRow()
    {
        var rows = IssueRow.Group(
        [
            new PdfAIssue("6.2.4.3", PdfAText.PageName(2), "A colour has no profile."),
            new PdfAIssue("6.2.4.3", PdfAText.PageName(5), "A colour has no profile."),
            new PdfAIssue("6.2.4.3", PdfAText.PageName(2), "A colour has no profile."),
            new PdfAIssue("6.3.4", PdfAText.FontName("ABCDEF+Arial"), "The font is not embedded."),
        ]);

        Assert.Equal(2, rows.Count);
        Assert.Equal("A colour has no profile.", rows[0].Message);
        Assert.Equal("Page 2, and 2 more", rows[0].Where);
        Assert.Equal("ISO 19005 clause 6.2.4.3", rows[0].Clause);
        Assert.Equal("Font ABCDEF+Arial", rows[1].Where);
    }

    [Fact]
    public void OnlyPlacesThatNameAPageCanBeVisitedAndTheyComeInTurn()
    {
        var rows = IssueRow.Group(
        [
            new PdfAIssue("6.5.3", PdfAText.AnnotationName(4, 1), "An annotation has no appearance."),
            new PdfAIssue("6.5.3", PdfAText.PageName(2), "An annotation has no appearance."),
            new PdfAIssue("6.5.3", PdfAText.Catalog, "An annotation has no appearance."),
            new PdfAIssue("6.1.3", PdfAText.Trailer, "The trailer has no /ID."),
        ]);

        var annotation = rows[0];
        Assert.True(annotation.HasPlaces);
        Assert.Equal("Go to page 2", annotation.PlaceText);
        Assert.Equal(1, annotation.NextPage());
        Assert.Equal(3, annotation.NextPage());
        Assert.Equal(1, annotation.NextPage());
        Assert.False(rows[1].HasPlaces);
    }

    [Fact]
    public void ARealCheckListsRulesInPlainWords()
    {
        var report = PdfAValidator.Validate(PdfDocument.Open(Pdfs.Text()), PdfALevel.A2b);

        var rows = IssueRow.Group(report.Issues);

        Assert.False(report.IsValid);
        Assert.NotEmpty(rows);
        Assert.All(rows, r => Assert.False(string.IsNullOrWhiteSpace(r.Message)));
    }

    [Fact]
    public void AConvertedFileIsStatedAsPassingTheChecksNeverAsConforming()
    {
        var made = new PdfAConverter(new FakeFonts()).Convert(Pdfs.Text(), PdfALevel.A2b, new DateTimeOffset(2026, 3, 1, 9, 0, 0, TimeSpan.Zero));

        Assert.NotNull(made.Bytes);
        var report = PdfAValidator.Validate(PdfDocument.Open(made.Bytes), PdfALevel.A2b);
        var text = StandardsText.ConvertedText(made, PdfALevel.A2b);

        if (made.IsClean)
        {
            Assert.True(report.IsValid);
            Assert.Contains("passes Lazy PDF's checks for PDF/A-2b", text);
        }
        else
        {
            Assert.Contains("still breaks", text);
        }
        Assert.DoesNotContain("conform", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("compliant", text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AFileWithoutOwnerRightsIsRefusedWithTheReasonCoreGives()
    {
        var refused = new PdfAConverter(new FakeFonts()).Convert(Pdfs.Restricted(PdfPermissions.Print), PdfALevel.A2b, DateTimeOffset.UnixEpoch);

        Assert.Null(refused.Bytes);
        Assert.False(string.IsNullOrWhiteSpace(refused.Refusal));
    }

    [Fact]
    public void EveryLevelHasAWordForWhatItIsFor()
    {
        foreach (var level in Enum.GetValues<PdfALevel>()) Assert.False(string.IsNullOrWhiteSpace(StandardsText.Describe(level)));
    }

    private static Func<PdfDocument> Copy(string? language, bool tagged = true)
    {
        var document = PdfDocument.Open(Pdfs.Text());
        if (tagged) AutoTagger.Tag(document, AccessibilityEdits.TagOptions(language));
        byte[] bytes = document.SaveRewrite();
        return () => PdfDocument.Open(bytes);
    }

    [Fact]
    public void AnUntaggedFileOrOneTheLevelRejectsNeedsTaggingOnlyAtLevelA()
    {
        Assert.True(StandardsText.NeedsTagging(Copy(null, tagged: false), PdfALevel.A2a));
        Assert.False(StandardsText.NeedsTagging(Copy(null, tagged: false), PdfALevel.A2b));
        Assert.True(StandardsText.NeedsTagging(Copy(null), PdfALevel.A1a));
        Assert.False(StandardsText.NeedsTagging(Copy("en-US"), PdfALevel.A1a));
    }

    [Fact]
    public void TheHintNamesTheLevel()
    {
        Assert.Equal("PDF/A-3a needs a tagged file, and this one is not tagged well enough yet. Tag the file first, then run this again.",
            StandardsText.TagHint(PdfALevel.A3a));
    }
}
