using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ExportLayoutTests
{
    private static readonly ExportDocument Report = ExportLayout.Analyze(ExportKit.Report());

    [Fact]
    public void ThreePagesComeOutWithTheirSizeAndTitle()
    {
        Assert.Equal(3, Report.Pages.Count);
        Assert.All(Report.Pages, p => Assert.Equal((612, 792), (p.Width, p.Height)));
        Assert.Null(Report.Title);
        Assert.Equal(11, Report.BodySize);
    }

    [Fact]
    public void RunningHeadAndPageNumberAreLeftOutOfTheFlowButKeptWithTheirPlace()
    {
        foreach (var page in Report.Pages)
        {
            var text = string.Join("\n", page.Blocks.OfType<ExportParagraph>().Select(p => p.Text));
            Assert.DoesNotContain("Confidential", text);
            Assert.DoesNotContain(page.Blocks.OfType<ExportParagraph>(), p => p.Text == (page.Index + 1).ToString());
            Assert.Contains(page.Lines, l => l.Text == "Confidential" && l.Bounds.Y < 40);
        }
    }

    [Fact]
    public void ALargerLineIsAHeading()
    {
        var heading = Assert.Single(Report.Pages[0].Blocks.OfType<ExportParagraph>(), p => p.Heading > 0);
        Assert.Equal("Annual Report", heading.Text);
        Assert.Equal(1, heading.Heading);
    }

    [Fact]
    public void LinesOfOneParagraphJoinAndAGapStartsAnother()
    {
        var paragraphs = Report.Pages[0].Blocks.OfType<ExportParagraph>().Where(p => p.Heading == 0 && p.Item is null).ToList();
        Assert.Equal("First line of the opening paragraph that runs on to a second line and stops there.", paragraphs[0].Text);
        Assert.Equal("Second paragraph with important words.", paragraphs[1].Text);
    }

    [Fact]
    public void BoldAndItalicRunsAreKept()
    {
        var paragraph = Report.Pages[0].Blocks.OfType<ExportParagraph>().Single(p => p.Text.StartsWith("Second paragraph"));
        // A space belongs to the run before it.
        Assert.Collection(paragraph.Runs,
            r => Assert.Equal(("Second paragraph with", false, false), (r.Text.Trim(), r.Bold, r.Italic)),
            r => Assert.Equal(("important", true, false), (r.Text.Trim(), r.Bold, r.Italic)),
            r => Assert.Equal(("words.", false, true), (r.Text.Trim(), r.Bold, r.Italic)));
    }

    [Fact]
    public void BulletsAndNumbersMakeTwoLists()
    {
        var items = Report.Pages[0].Blocks.OfType<ExportParagraph>().Where(p => p.Item is not null).ToList();
        Assert.Equal(["Apples", "Pears", "First step", "Second step"], items.Select(p => p.Text));
        Assert.Equal([false, false, true, true], items.Select(p => p.Item!.Ordered));
        Assert.Equal(items[0].Item!.ListId, items[1].Item!.ListId);
        Assert.NotEqual(items[1].Item!.ListId, items[2].Item!.ListId);
        Assert.Equal(items[2].Item!.ListId, items[3].Item!.ListId);
        Assert.Equal(1, items[2].Item!.Number);
        Assert.All(items, i => Assert.Equal(0, i.Item!.Level));
    }

    [Fact]
    public void AGridOfRulesIsATableWithItsText()
    {
        var table = Assert.Single(Report.Pages[1].Blocks.OfType<ExportTable>());
        Assert.True(table.Ruled);
        Assert.Equal("Item|Price;Tea|1,250.50", string.Join(';', table.Rows.Select(r => string.Join('|', r))));
        Assert.Equal([150, 150], table.Widths!.Select(w => Math.Round(w)));
        Assert.DoesNotContain(Report.Pages[1].Blocks.OfType<ExportParagraph>(), p => p.Text.Contains("Tea"));
    }

    [Fact]
    public void ThePictureSitsWhereItWasPaintedAndKeepsItsJpegBytes()
    {
        var picture = Assert.Single(Report.Pages[0].Pictures);
        Assert.True(picture.Image.IsJpeg);
        Assert.Equal(ExportKit.Jpeg, picture.Image.Data);
        Assert.Equal((72, 470, 96, 72), (picture.Bounds.X, picture.Bounds.Y, picture.Bounds.Width, picture.Bounds.Height));
        Assert.Contains(picture, Report.Pages[0].Blocks.OfType<ExportPicture>());
        var flow = Report.Pages[0].Blocks.ToList();
        Assert.True(flow.IndexOf(picture) > flow.FindIndex(b => b is ExportTable));
    }

    [Fact]
    public void ThePictureIsDecodedOncePerImageObject()
    {
        Assert.Same(Report.Pages[0].Pictures[0].Image, Report.Pages[2].Pictures[0].Image);
    }

    [Fact]
    public void ABoldLineAtBodySizeIsAHeadingOneLevelDown()
    {
        var document = ExportLayout.Analyze(ExportKit.Open(
            "BT /F1 11 Tf 72 700 Td (Some body text that goes on for a while here.) Tj ET\nBT /F2 11 Tf 72 660 Td (Background) Tj ET\nBT /F1 11 Tf 72 640 Td (More body text that goes on for a while here.) Tj ET"));
        var blocks = document.Pages[0].Blocks.OfType<ExportParagraph>().ToList();
        Assert.Equal([0, 1, 0], blocks.Select(b => b.Heading));
    }

    [Fact]
    public void SizesPickTheHeadingLevels()
    {
        var document = ExportLayout.Analyze(ExportKit.Open(
            "BT /F2 24 Tf 72 740 Td (Title) Tj ET\nBT /F2 16 Tf 72 700 Td (Chapter) Tj ET\nBT /F1 11 Tf 72 670 Td (Body text that fills a line of the page nicely.) Tj ET\nBT /F1 11 Tf 72 656 Td (More body text that fills a line of the page nicely.) Tj ET"));
        Assert.Equal([1, 2, 0], document.Pages[0].Blocks.OfType<ExportParagraph>().Select(b => b.Heading));
    }

    [Fact]
    public void AlignedColumnsWithoutRulesAreATable()
    {
        var rows = new[] { ("Name", "Qty", "Price"), ("Tea", "3", "4.50"), ("Coffee", "12", "18.00"), ("Milk", "7", "2.25") };
        var content = string.Join("\n", rows.Select((r, i) => $"BT /F1 11 Tf 72 {700 - 16 * i} Td ({r.Item1}) Tj ET BT /F1 11 Tf 220 {700 - 16 * i} Td ({r.Item2}) Tj ET BT /F1 11 Tf 320 {700 - 16 * i} Td ({r.Item3}) Tj ET"));
        var table = Assert.Single(ExportLayout.Analyze(ExportKit.Open(content)).Pages[0].Blocks.OfType<ExportTable>());
        Assert.False(table.Ruled);
        Assert.Equal(4, table.Rows.Count);
        Assert.Equal(["Coffee", "12", "18.00"], table.Rows[2]);
        Assert.Null(table.Widths);
    }

    [Fact]
    public void AnInvisibleTextScanDropsThePagePicture()
    {
        var document = ExportLayout.Analyze(ExportKit.Open("q 612 0 0 792 0 0 cm /Im1 Do Q\nBT 3 Tr /F1 12 Tf 72 700 Td (Scanned words here) Tj ET"));
        Assert.Empty(document.Pages[0].Pictures);
        Assert.Equal("Scanned words here", Assert.Single(document.Pages[0].Blocks.OfType<ExportParagraph>()).Text);
    }

    [Fact]
    public void ARotatedPageIsAnalysedAsShown()
    {
        var bytes = System.Text.Encoding.Latin1.GetString(ExportKit.Build("BT /F1 12 Tf 72 700 Td (Rotated page) Tj ET")).Replace("/Type /Page /Parent", "/Type /Page /Rotate 90 /Parent");
        var document = ExportLayout.Analyze(PdfDocument.Open(System.Text.Encoding.Latin1.GetBytes(bytes)));
        var page = document.Pages[0];
        Assert.Equal((792, 612), (page.Width, page.Height));
        Assert.Equal("Rotated page", Assert.Single(page.Blocks.OfType<ExportParagraph>()).Text);
    }

    [Fact]
    public void PagesCanBeChosenAndABadIndexIsRefused()
    {
        var document = ExportLayout.Analyze(ExportKit.Report(), [2, 0]);
        Assert.Equal([2, 0], document.Pages.Select(p => p.Index));
        Assert.Throws<ArgumentOutOfRangeException>(() => ExportLayout.Analyze(ExportKit.Report(), [3]));
    }

    [Fact]
    public void AnEmptyPageGivesAnEmptyFlow()
    {
        var document = ExportLayout.Analyze(ExportKit.Open(""));
        Assert.Empty(document.Pages[0].Blocks);
        Assert.Equal(11, document.BodySize);
    }

    [Fact]
    public void CancellationIsHonoured()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => ExportLayout.Analyze(ExportKit.Report(), cancel: cts.Token));
    }

    [Fact]
    public void ADamagedContentStreamStillGivesWhatReadsBeforeIt()
    {
        var document = ExportLayout.Analyze(ExportKit.Open("BT /F1 12 Tf 72 700 Td (Good text) Tj ET\n(((( [[ BT /Zz"));
        Assert.Contains("Good text", document.Pages[0].Blocks.OfType<ExportParagraph>().Select(p => p.Text));
    }
}
