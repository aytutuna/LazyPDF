using System.Windows;
using LazyPDF.App.Tools.Redact;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What the Redact tool asks of Core: finding, applying with and without flattening, and what it says afterwards.
public sealed class RedactJobTests
{
    private const string Line = "Write to ann@example.com today.";

    // Draws blank pages of the size the page has at that resolution, which is all Core checks before it uses the picture.
    private sealed class BlankPages(byte[] pdf) : IPageRenderer
    {
        public PdfRgbaImage? Render(int pageIndex, double dpi)
        {
            using var document = PdfDocument.Open(pdf);
            var page = new PageGeometry(document.Pages[pageIndex]);
            int width = (int)Math.Round(page.Width * dpi / 72), height = (int)Math.Round(page.Height * dpi / 72);
            return new PdfRgbaImage(width, height, Enumerable.Repeat((byte)255, width * height * 4).ToArray());
        }
    }

    private static readonly RedactSettings Plain = new(Cover.All[0], null, false);

    private static string TextOf(byte[] pdf, int page = 0)
    {
        using var document = PdfDocument.Open(pdf);
        return new TextCache(document).Get(page).Text;
    }

    private static IReadOnlyList<MarkItem> FindAddresses(byte[] pdf)
    {
        using var document = RedactJob.Open(pdf, null, null);
        return RedactJob.Find(document, DataKind.All.First(k => k.Kind == RedactionKind.Email), CancellationToken.None).Items;
    }

    private static RedactionResult Apply(byte[] pdf, IReadOnlyList<MarkItem> marks, RedactSettings settings, IFontSource? fonts = null) =>
        RedactJob.Apply(pdf, null, null, [.. marks.Select(m => m.Mark)], settings, new BlankPages(pdf), fonts ?? new FakeFonts(), new FakeCodec());

    [Fact]
    public void AKindOfDataIsFoundOnEveryPage()
    {
        var found = FindAddresses(Pdfs.Text(2, Line));

        Assert.Equal([0, 1], found.Select(m => m.Page));
        Assert.All(found, m => Assert.Equal("ann@example.com", m.Label));
    }

    [Fact]
    public void AWordIsFoundWholeOrInsideAnotherWord()
    {
        var pdf = Pdfs.Text(1, Line);
        using var document = RedactJob.Open(pdf, null, null);

        var inside = RedactJob.Find(document, "to", false, false, CancellationToken.None).Items;
        var whole = RedactJob.Find(document, "to", false, true, CancellationToken.None).Items;
        var wrongCase = RedactJob.Find(document, "WRITE", true, true, CancellationToken.None).Items;

        Assert.Equal(2, inside.Count);
        Assert.Single(whole);
        Assert.Empty(wrongCase);
    }

    [Fact]
    public void ALongLabelIsClippedToOneLine()
    {
        string label = RedactJob.Clip("one\ntwo   three " + new string('x', 80));

        Assert.StartsWith("one two three x", label);
        Assert.Equal(40, label.Length);
        Assert.EndsWith("…", label);
    }

    [Fact]
    public void WhatIsMarkedIsGoneFromTheCopyAndTheCheckPasses()
    {
        var pdf = Pdfs.Text(2, Line);
        var original = pdf.ToArray();

        var result = Apply(pdf, FindAddresses(pdf), Plain);

        Assert.DoesNotContain("example", TextOf(result.Bytes, 0));
        Assert.DoesNotContain("example", TextOf(result.Bytes, 1));
        Assert.Contains("Write to", TextOf(result.Bytes));
        Assert.True(result.Verification.IsClean);
        Assert.Equal(original, pdf);
        Assert.Empty(result.Report.Flattened);
        var summary = RedactSummary.Of(result);
        Assert.True(summary.Clean);
        Assert.Equal("", summary.Problems);
        Assert.Contains("Page 1: removed", summary.Report);
    }

    [Fact]
    public void ABoxOverTextTakesTheTextUnderIt()
    {
        var pdf = Pdfs.Text(1, Line);
        using var document = PdfDocument.Open(pdf);
        var page = new TextCache(document).Get(0);
        var geometry = new PageGeometry(document.Pages[0]);
        var quad = page.Quads(new TextRange(0, 5))[0];
        var top = geometry.ToDisplay(quad.Bounds.Left - 1, quad.Bounds.Top + 1);
        var bottom = geometry.ToDisplay(quad.Bounds.Right + 1, quad.Bounds.Bottom - 1);
        var box = MarkShapes.Box(0, geometry, new Point(top.X, top.Y), new Point(bottom.X, bottom.Y));

        var result = Apply(pdf, [new MarkItem(box, "Box")], Plain);

        Assert.StartsWith("to", TextOf(result.Bytes).TrimStart());
        Assert.DoesNotContain("Write", TextOf(result.Bytes));
    }

    [Fact]
    public void EveryMarkedPageCanBeMadeAPicture()
    {
        var pdf = Pdfs.Text(3, Line);
        var marks = FindAddresses(pdf).Where(m => m.Page != 1).ToList();

        var result = Apply(pdf, marks, Plain with { FlattenAll = true });

        Assert.Equal([0, 2], result.Report.Flattened);
        Assert.Equal("", TextOf(result.Bytes, 0));
        Assert.Contains("Page 2", TextOf(result.Bytes, 1));
        Assert.Equal("", TextOf(result.Bytes, 2));
        var summary = RedactSummary.Of(result);
        Assert.Contains("Pages 1, 3 are now pictures", summary.Report);
        Assert.DoesNotContain("Page 1 was turned into a picture", summary.Report);
    }

    [Fact]
    public void TextOnTheBoxesIsDrawnWithoutASystemFont()
    {
        var pdf = Pdfs.Text(1, Line);

        var result = Apply(pdf, FindAddresses(pdf), Plain with { OverlayText = " REMOVED " });

        Assert.Contains("REMOVED", TextOf(result.Bytes));
        Assert.DoesNotContain("example", TextOf(result.Bytes));
        Assert.True(result.Verification.IsClean);
    }

    [Fact]
    public void AnOverlayWithNoFontForItIsSaidInOurWords()
    {
        var pdf = Pdfs.Text(1, Line);

        var error = Assert.Throws<InvalidOperationException>(() => Apply(pdf, FindAddresses(pdf), Plain with { OverlayText = "编辑" }));
        var problem = RedactJob.Failed(error);

        Assert.Equal(RedactionText.NoFont, error.Message);
        Assert.Equal("Not redacted", problem.Title);
        Assert.DoesNotContain(RedactionText.NoFont, problem.Text);
    }

    [Fact]
    public void AMarkOnAPageThatIsNotThereIsLeftOut()
    {
        var pdf = Pdfs.Text(1, Line);

        var result = Apply(pdf, [new MarkItem(RedactionMark.FromRect(5, new PdfRect(0, 0, 50, 50)), "Box")], Plain);

        Assert.True(result.Report.Pages.Count == 0);
        Assert.Equal(RedactionText.NothingFound, RedactSummary.Of(result).Report);
    }

    [Fact]
    public void TheCopyOfAFileOpenedWithItsPasswordOpensWithoutOne()
    {
        var plain = PdfDocument.Open(Pdfs.Text(1, Line));
        var security = PdfSecurity.Create("secret", "owner", PdfPermissions.Print, PdfCryptStrength.Aes256, plain.FirstId ?? []);
        var pdf = plain.SaveRewrite(new PdfSaveOptions(Security: security));
        using var opened = PdfDocument.Open(pdf, "owner");
        var marks = RedactJob.Find(opened, DataKind.All[0], CancellationToken.None).Items;

        var result = RedactJob.Apply(pdf, "owner", null, [.. marks.Select(m => m.Mark)], Plain, new BlankPages(pdf), new FakeFonts(), new FakeCodec());

        Assert.False(PdfDocument.Open(result.Bytes).IsEncrypted);
        Assert.DoesNotContain("example", TextOf(result.Bytes));
    }

    [Fact]
    public void AFileThatForbidsChangesIsRefusedAndSaidSo()
    {
        var pdf = Pdfs.Restricted(PdfPermissions.Print);
        var mark = RedactionMark.FromRect(0, new PdfRect(0, 0, 100, 100));

        var error = Assert.Throws<PdfPermissionException>(() =>
            RedactJob.Apply(pdf, null, null, [mark], Plain, new BlankPages(pdf), new FakeFonts(), new FakeCodec()));
        var problem = RedactJob.Failed(error);

        Assert.Equal("Not redacted", problem.Title);
        Assert.Contains("Ask its owner", problem.Text);
    }

    [Fact]
    public void ADigitOfAnotherScriptIsNotASocialSecurityNumber()
    {
        var pdf = PdfFromText.Create("١٢٣-٤٥-٦٧٨٩", new SystemFontSource()).Bytes;
        using var document = RedactJob.Open(pdf, null, null);

        var found = RedactJob.Find(document, DataKind.All.First(k => k.Kind == RedactionKind.UsSocialSecurity), CancellationToken.None);

        Assert.Empty(found.Items);
    }

    [Fact]
    public void PagesWithNoTextAreCountedSoThatNothingFoundIsNotTakenForClean()
    {
        var pdf = PdfFromText.Create("ann@example.commore", new FakeFonts()).Bytes;
        using var document = RedactJob.Open(pdf, null, null);

        var found = RedactJob.Find(document, DataKind.All[0], CancellationToken.None);

        Assert.Single(found.Items);
        Assert.Equal(1, found.Pictures);
    }

    [Fact]
    public void AFileThatForbidsChangesIsKnownBeforeAnythingIsMarked()
    {
        using var restricted = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print));
        using var owned = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print), "owner");
        using var plain = PdfDocument.Open(Pdfs.Text());

        Assert.True(RedactJob.Refuses(restricted));
        Assert.False(RedactJob.Refuses(owned));
        Assert.False(RedactJob.Refuses(plain));
    }

    [Fact]
    public void AnUnexpectedErrorIsNotShownInTheFrameworksWords()
    {
        var problem = RedactJob.Failed(new InvalidOperationException("Sequence contains no elements"));

        Assert.DoesNotContain("Sequence", problem.Text);
        Assert.Contains("The file was not changed", problem.Text);
    }

    [Theory]
    [InlineData(false, "Flattening every marked page")]
    [InlineData(true, "Read the problems below.")]
    public void AdviceAfterAFailedCheckDoesNotSendYouBackToWhatWasAlreadyDone(bool flattenedAll, string expected)
    {
        var report = new RedactionReport([], [], 0, []);
        var result = new RedactionResult([], report, new RedactionVerification(["Page 3 could not be followed to its end, so it was not fully checked."]));

        var summary = RedactSummary.Of(result, flattenedAll);

        Assert.False(summary.Clean);
        Assert.Contains(expected, summary.Advice);
        Assert.Equal(!flattenedAll, summary.Advice.Contains("Flattening"));
    }

    [Fact]
    public void ThePassedCardSaysWhatTheCheckDidNotLookAt()
    {
        var report = new RedactionReport([], [], 0, []);
        var summary = RedactSummary.Of(new RedactionResult([], report, new RedactionVerification([])));

        Assert.True(summary.Clean);
        Assert.DoesNotContain("left in the copy", summary.Advice);
        Assert.Contains("not marked", summary.NotChecked);
    }

    [Fact]
    public async Task TheCopyOpensAsANewFileThatHasToBeNamed()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Pdf());
        var tab = f.Vm.ActiveDocument!;
        var bytes = tab.Session.Current.ToArray();
        var marks = FindAddresses(bytes);
        var result = RedactJob.Apply(bytes, tab.Password, tab.Certificate, [.. marks.Select(m => m.Mark)], Plain, tab.Renderer, new FakeFonts(), new FakeCodec());

        await f.Vm.OpenNewAsync(result.Bytes, "a (redacted).pdf");

        Assert.Equal(2, f.Vm.Documents.Count());
        Assert.True(AppViewModel.NeedsName(f.Vm.ActiveDocument!));
        Assert.False(tab.IsDirty);
    }
}
