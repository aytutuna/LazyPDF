using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.App.Tests.PagesKit;

namespace LazyPDF.App.Tests;

// Pages copied from one open tab into another, and out into a tab of their own, without the grids in between.
[Collection("Application")]
public sealed class PageTransferTests
{
    private static DocumentTab Tab(byte[] bytes, string title) => new(PdfEditSession.Open(bytes), new FakeRenderer(), null, title);

    private static StageHost Hosting(params DocumentTab[] tabs)
    {
        var host = new StageHost();
        host.Documents.AddRange(tabs);
        return host;
    }

    private static PagePayload Pick(DocumentTab tab, params int[] pages) => new(tab, pages, tab.Revision);

    private static byte[] Locked(PdfPermissions allowed, int pages = 4)
    {
        var document = PdfDocument.Open(Pdfs.Text(pages));
        var security = PdfSecurity.Create("", "owner", allowed, PdfCryptStrength.Aes256, document.FirstId ?? []);
        return document.SaveRewrite(new PdfSaveOptions(Security: security));
    }

    [Fact]
    public Task CopiedPagesGoLastInTheTargetAndLeaveTheSourceAlone() => Sta.Run(async () =>
    {
        using var from = Open(6, "a.pdf");
        using var to = Tab(Pdfs.Text(6, "Other"), "b.pdf");
        var host = Hosting(from, to);
        var fromOrder = Order(from);
        var toOrder = Order(to);
        int fromRevision = from.Revision;

        await PageTransfer.CopyAsync(Pick(from, 1, 2), to, host);

        Assert.Equal(8, to.PageCount);
        Assert.Equal(toOrder, Order(to).Take(6));
        Assert.Equal(fromOrder[1], TextOf(to, 6));
        Assert.Equal(fromOrder[2], TextOf(to, 7));
        Assert.Equal(fromOrder, Order(from));
        Assert.Equal(fromRevision, from.Revision);
        Assert.False(from.Session.CanUndo);
        Assert.Equal("Copied 2 pages to b.pdf. Undo it in b.pdf.", host.Status);
        Assert.Empty(host.Problems);
        to.Undo();
        Assert.Equal(toOrder, Order(to));
    });

    [Fact]
    public Task APageGoesIntoAOnePageFile() => Sta.Run(async () =>
    {
        using var from = Open(3, "a.pdf");
        using var to = Tab(Pdfs.Text(1, "Other"), "b.pdf");

        await PageTransfer.CopyAsync(Pick(from, 2), to, Hosting(from, to));

        Assert.Equal(2, to.PageCount);
        Assert.Equal(TextOf(from, 2), TextOf(to, 1));
    });

    [Fact]
    public Task ARotatedPageKeepsItsShape() => Sta.Run(async () =>
    {
        using var from = Open(2, "a.pdf");
        using var to = Tab(Pdfs.Text(1, "Other"), "b.pdf");
        PageOperations.Rotate(from.Document, [0], 90);
        from.Document.Pages[0].Dictionary["UserUnit"] = new PdfNumber(2);
        Assert.True(from.Commit("Rotate"));

        await PageTransfer.CopyAsync(Pick(from, 0), to, Hosting(from, to));

        var was = new PageGeometry(from.Document.Pages[0]);
        var now = new PageGeometry(to.Document.Pages[1]);
        Assert.Equal(was.Width, now.Width);
        Assert.Equal(was.Height, now.Height);
        Assert.NotEqual(new PageGeometry(to.Document.Pages[0]).Width, now.Width);
    });

    [Fact]
    public Task APageThatTakesItsSizeFromThePagesNodeKeepsIt() => Sta.Run(async () =>
    {
        var source = PdfDocument.Open(Pdfs.Text(3, "From"));
        source.Dict(source.Catalog, "Pages")!["MediaBox"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(300), new PdfNumber(400)]);
        foreach (var page in source.Pages) page.Dictionary.Remove("MediaBox");
        using var from = Tab(source.SaveRewrite(), "a.pdf");
        using var to = Tab(Pdfs.Text(1, "Other"), "b.pdf");
        Assert.False(from.Document.Pages[1].Dictionary.ContainsKey("MediaBox"));

        await PageTransfer.CopyAsync(Pick(from, 1), to, Hosting(from, to));

        var copied = to.Document.Pages[1];
        Assert.True(copied.Dictionary.ContainsKey("MediaBox"));
        Assert.Equal(300, copied.MediaBox.Width);
        Assert.Equal(400, copied.MediaBox.Height);
    });

    [Fact]
    public Task AFormFieldThatClashesWithOneInTheTargetIsRenamedAndBothAreKept() => Sta.Run(async () =>
    {
        using var from = Tab(FormPdfs.Standard(), "a.pdf");
        using var to = Tab(FormPdfs.Standard(), "b.pdf");
        var before = PdfForm.Read(to.Document, new FakeFonts()).Fields.Select(f => f.Name).ToList();
        var host = Hosting(from, to);

        await PageTransfer.CopyAsync(Pick(from, 0), to, host);

        var names = PdfForm.Read(to.Document, new FakeFonts()).Fields.Select(f => f.Name).ToList();
        Assert.Equal(before.Count * 2, names.Count);
        Assert.Equal(names.Count, names.Distinct().Count());
        Assert.All(before, name => Assert.Contains(name, names));
        Assert.Empty(host.Problems);
    });

    [Fact]
    public Task AnObjectThatCouldNotBeReadIsSaidToBeLeftOutOfTheCopy() => Sta.Run(async () =>
    {
        using var from = Tab(Pdfs.WithUnreadableObject(), "a.pdf");
        using var to = Open(2, "b.pdf");
        var host = Hosting(from, to);

        await PageTransfer.CopyAsync(Pick(from, 0), to, host);

        Assert.Equal(3, to.PageCount);
        Assert.Equal("Objects left out", Assert.Single(host.Notices));
        Assert.Equal(PageJobs.DroppedText(1), host.NoticeTexts[0]);
    });

    [Fact]
    public Task ASourceThatLimitsCopyingIsRefusedAndTheTargetStaysAsItWas() => Sta.Run(async () =>
    {
        using var from = Tab(Locked(PdfPermissions.Print), "locked.pdf");
        using var to = Open(2, "b.pdf");
        var host = Hosting(from, to);
        int revision = to.Revision;

        await PageTransfer.CopyAsync(Pick(from, 0), to, host);

        Assert.Equal("File is protected", Assert.Single(host.Problems).Title);
        Assert.Equal(revision, to.Revision);
        Assert.Equal(2, to.PageCount);
    });

    [Fact]
    public Task AnEncryptedSourceWithFullRightsCopiesAndSaysTheCopyIsNotProtected() => Sta.Run(async () =>
    {
        using var from = Tab(Locked(PdfPermissions.All), "locked.pdf");
        using var to = Tab(Locked(PdfPermissions.All, 2), "also.pdf");
        var host = Hosting(from, to);

        await PageTransfer.CopyAsync(Pick(from, 0), to, host);

        Assert.Equal(3, to.PageCount);
        Assert.True(to.Document.IsEncrypted);
        Assert.Equal("Copy is not protected", Assert.Single(host.Notices));
    });

    [Fact]
    public Task ATargetThatForbidsChangesRefusesAndNamesItself() => Sta.Run(async () =>
    {
        using var from = Open(2, "a.pdf");
        using var to = Tab(Locked(PdfPermissions.Print), "locked.pdf");
        var host = Hosting(from, to);
        int revision = to.Revision;

        await PageTransfer.CopyAsync(Pick(from, 0), to, host);

        var problem = Assert.Single(host.Problems);
        Assert.Equal("locked.pdf cannot be changed", problem.Title);
        Assert.Contains("locked.pdf", problem.Text);
        Assert.Equal(revision, to.Revision);
    });

    [Fact]
    public Task ASignedTargetAsksFirstNamingItselfAndTakesExactlyOneCopy() => Sta.Run(async () =>
    {
        using var from = Open(2, "a.pdf");
        using var to = Tab(StampsPanelTests.Signed(false, 2), "signed.pdf");
        var host = Hosting(from, to);
        int revision = to.Revision;

        await PageTransfer.CopyAsync(Pick(from, 0, 1), to, host);

        Assert.Equal(revision, to.Revision);
        Assert.Equal("Check before going on", Assert.Single(host.Notices));
        Assert.Contains("signed.pdf", host.NoticeTexts[0]);
        host.Actions[0]!.Run();
        await Sta.Until(() => to.Revision > revision);

        Assert.Equal(4, to.PageCount);
        Assert.Single(host.Notices);
        Assert.Empty(host.Problems);
    });

    [Fact]
    public Task PagesThatChangedSinceThePickAreNotCopied() => Sta.Run(async () =>
    {
        using var from = Open(4, "a.pdf");
        using var to = Open(2, "b.pdf");
        var host = Hosting(from, to);
        var pick = Pick(from, 0, 1);
        PageOperations.Delete(from.Document, [3]);
        Assert.True(from.Commit("Delete"));

        await PageTransfer.CopyAsync(pick, to, host);

        Assert.Equal(2, to.PageCount);
        Assert.Equal("Pages not copied", Assert.Single(host.Problems).Title);
    });

    [Fact]
    public Task PagesBeyondTheEndOfTheSourceAreNotCopied() => Sta.Run(async () =>
    {
        using var from = Open(2, "a.pdf");
        using var to = Open(2, "b.pdf");
        var host = Hosting(from, to);

        await PageTransfer.CopyAsync(Pick(from, 5), to, host);

        Assert.Equal(2, to.PageCount);
        Assert.Single(host.Problems);
    });

    [Fact]
    public Task AClosedTabOnEitherSideIsRefused() => Sta.Run(async () =>
    {
        using var from = Open(2, "a.pdf");
        using var to = Open(2, "b.pdf");

        var gone = Hosting(from);
        await PageTransfer.CopyAsync(Pick(from, 0), to, gone);
        var sourceGone = Hosting(to);
        await PageTransfer.CopyAsync(Pick(from, 0), to, sourceGone);

        Assert.Equal(2, to.PageCount);
        Assert.Single(gone.Problems);
        Assert.Single(sourceGone.Problems);
    });

    [Fact]
    public Task ARunningJobHoldsACopyBack() => Sta.Run(async () =>
    {
        using var from = Open(2, "a.pdf");
        using var to = Open(2, "b.pdf");
        var host = Hosting(from, to);
        MarkWork.Running = true;
        try
        {
            await PageTransfer.CopyAsync(Pick(from, 0), to, host);
        }
        finally
        {
            MarkWork.Running = false;
        }

        Assert.Equal(2, to.PageCount);
        Assert.Single(host.Problems);
    });

    private sealed class UnfinishedRenderer : IDocumentRenderer
    {
        public bool Load(PdfEditSession session, string? password) => true;

        public Task<bool> LoadAsync(PdfEditSession session, string? password) => new TaskCompletionSource<bool>().Task;

        public (double Width, double Height) PageSize(int pageIndex) => (200, 300);

        public PdfRgbaImage? Render(int pageIndex, double dpi) => null;

        public void Dispose() { }
    }

    [Fact]
    public Task ATargetThatIsStillLoadingIsRefusedWithANotice() => Sta.Run(async () =>
    {
        using var from = Open(2, "a.pdf");
        using var to = new DocumentTab(PdfEditSession.Open(Pdfs.Text(2)), new UnfinishedRenderer(), null, "b.pdf");
        var host = Hosting(from, to);
        Pdfs.Retitle(to.Session, "New title");
        to.Commit("Properties");

        await PageTransfer.CopyAsync(Pick(from, 0), to, host);

        Assert.Equal(2, to.PageCount);
        var problem = Assert.Single(host.Problems);
        Assert.Equal("b.pdf is still loading. Try again in a moment.", problem.Text);
    });

    [Fact]
    public Task CopyingIntoTheSameTabDoesNothing() => Sta.Run(async () =>
    {
        using var tab = Open(3, "a.pdf");
        var host = Hosting(tab);

        await PageTransfer.CopyAsync(Pick(tab, 0), tab, host);

        Assert.Equal(3, tab.PageCount);
        Assert.Empty(host.Problems);
    });

    [Fact]
    public Task CancellingTheBusyBarChangesNeitherTab() => Sta.Run(async () =>
    {
        using var from = Open(3, "a.pdf");
        using var to = Open(2, "b.pdf");
        var host = Hosting(from, to);
        host.Cancel.Cancel();

        await PageTransfer.CopyAsync(Pick(from, 0), to, host);

        Assert.Equal(2, to.PageCount);
        Assert.False(to.Session.CanUndo);
        Assert.Equal("Canceled.", host.Status);
    });

    [Fact]
    public Task APasteIndexPastTheEndGoesToTheEnd() => Sta.Run(async () =>
    {
        using var to = Open(2, "b.pdf");
        var host = Hosting(to);

        bool done = await PageTransfer.PasteAsync(to, host, Pdfs.Text(2, "Pasted"), 2, 9);

        Assert.True(done);
        Assert.Equal(4, to.PageCount);
        Assert.Empty(host.Problems);
    });

    [Fact]
    public Task PastingWithoutAPlaceGoesToTheEnd() => Sta.Run(async () =>
    {
        using var to = Open(2, "b.pdf");
        var was = Order(to);

        await PageTransfer.PasteAsync(to, Hosting(to), Pdfs.Text(1, "Pasted"), 1, null);

        Assert.Equal(was, Order(to).Take(2));
        Assert.Contains(Hex("Pasted"), TextOf(to, 2));
    });

    [Fact]
    public Task AToNewTabCopyOpensTheExtractWithoutAttachments() => Sta.Run(async () =>
    {
        using var from = Open(4, "a.pdf");
        var host = Hosting(from);
        int revision = from.Revision;

        await PageTransfer.ToNewTabAsync(Pick(from, 1, 3), host, files: false);

        Assert.Equal("a extract.pdf", Assert.Single(host.Opened));
        Assert.Equal(revision, from.Revision);
        Assert.Empty(host.Notices);
    });

    [Fact]
    public Task AToNewTabCopyOfStalePagesIsRefused() => Sta.Run(async () =>
    {
        using var from = Open(4, "a.pdf");
        var host = Hosting(from);

        await PageTransfer.ToNewTabAsync(Pick(from, 9), host, files: false);

        Assert.Empty(host.Opened);
        Assert.Single(host.Problems);
    });
}
