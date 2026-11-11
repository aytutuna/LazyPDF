using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Ocr;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The panel's actions on a real tab and the real window state, with a recognizer that returns fixed words.
public sealed class OcrWorkTests
{
    // Progress reports are posted to the context they were made in; here they run at once, so they land before the result does.
    private sealed class InlineContext : SynchronizationContext
    {
        public override void Post(SendOrPostCallback d, object? state) => d(state);
    }

    private sealed class FakeRecognizer : ITextRecognizer
    {
        public string[] Words { get; set; } = ["alpha", "beta"];
        public Exception? Fails { get; set; }
        public Action? OnRead { get; set; }
        // Words only for an image taller than wide, as a page that was scanned sideways reads once it is turned.
        public bool PortraitOnly { get; set; }
        public List<string> Languages { get; } = [];
        // Words per language tag; a tag not in it reads Words.
        public Dictionary<string, string[]> ByLanguage { get; } = [];

        public Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default)
        {
            OnRead?.Invoke();
            cancellation.ThrowIfCancellationRequested();
            if (Fails is not null) throw Fails;
            Languages.Add(language);
            var read = ByLanguage.GetValueOrDefault(language) ?? Words;
            IReadOnlyList<OcrWord> words = PortraitOnly && image.Width >= image.Height ? [] : [.. read.Select((w, i) => new OcrWord(w, new OcrBox(0, i, image.Width, 1)))];
            return Task.FromResult(words);
        }
    }

    private static async Task<DocumentTab> Open(ViewModelFixture f, int pages = 2)
    {
        await f.Vm.OpenAsync(f.Pdf("a.pdf", pages));
        return f.Vm.ActiveDocument!;
    }

    private static async Task<OcrResult?> Make(DocumentTab tab, ViewModelFixture f, FakeRecognizer recognizer, OcrOptions options)
    {
        var before = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(new InlineContext());
        try
        {
            return await OcrWork.MakeSearchableAsync(tab, f.Vm, recognizer, options);
        }
        finally
        {
            SynchronizationContext.SetSynchronizationContext(before);
        }
    }

    private static OcrOptions All(OcrExisting existing = OcrExisting.Skip, string language = "en-US") =>
        new(language, OcrWork.Dpi, existing, [0, 1], Force: true);

    private static IEnumerable<string> Words(DocumentTab tab, int page = 0) =>
        PdfOcrLayer.Words(tab.Document, tab.Document.Pages[page]).Select(w => w.Text);

    [Fact]
    public async Task PagesGetALayerAsOneUndoableStep()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f);
        int revision = tab.Revision;
        var recognizer = new FakeRecognizer();

        var result = await Make(tab, f, recognizer, All(language: "tr-TR"));

        Assert.Equal(2, result!.Added);
        Assert.All(tab.Document.Pages, p => Assert.True(PdfOcrLayer.Has(tab.Document, p)));
        Assert.Equal(["tr-TR", "tr-TR"], recognizer.Languages);
        Assert.Equal("tr-TR", PdfOcrLayer.Language(tab.Document, tab.Document.Pages[0]));
        Assert.True(tab.Revision > revision);
        Assert.Equal("Made 2 pages searchable", f.Vm.StatusFull);
        Assert.Equal("Make searchable", tab.Session.UndoLabel);

        Assert.True(tab.Undo());
        Assert.All(tab.Document.Pages, p => Assert.False(PdfOcrLayer.Has(tab.Document, p)));
    }

    [Fact]
    public async Task TheWordsOfTheLayerCanBeFoundAgain()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);

        await Make(tab, f, new FakeRecognizer(), All());

        Assert.Equal(["alpha", "beta"], Words(tab));
    }

    [Fact]
    public async Task KeepingLeavesAnExistingLayerAndReplacingChangesIt()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        await Make(tab, f, new FakeRecognizer(), All());

        var kept = await Make(tab, f, new FakeRecognizer { Words = ["gamma"] }, All(OcrExisting.Skip));
        Assert.Equal(1, kept!.Skipped);
        Assert.Equal(["alpha", "beta"], Words(tab));

        var replaced = await Make(tab, f, new FakeRecognizer { Words = ["gamma"] }, All(OcrExisting.Replace));
        Assert.Equal(1, replaced!.Added);
        Assert.Equal(["gamma"], Words(tab));
    }

    [Fact]
    public async Task OnlyTheChosenPagesAreRead()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 3);

        await Make(tab, f, new FakeRecognizer(), new("en-US", OcrWork.Dpi, OcrExisting.Skip, [1], Force: true));

        Assert.Equal([false, true, false], tab.Document.Pages.Select(p => PdfOcrLayer.Has(tab.Document, p)));
    }

    [Fact]
    public async Task ACancelKeepsThePagesAlreadyReadAsOneUndoableStep()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 3);
        var recognizer = new FakeRecognizer();
        int reads = 0;
        recognizer.OnRead = () =>
        {
            if (++reads == 2) f.Vm.CancelBusy();
        };

        var result = await Make(tab, f, recognizer, new("en-US", OcrWork.Dpi, OcrExisting.Skip, [0, 1, 2], Force: true));

        Assert.Null(result);
        Assert.Equal([true, false, false], tab.Document.Pages.Select(p => PdfOcrLayer.Has(tab.Document, p)));
        Assert.Equal("Reading stopped", f.Vm.Message!.Title);
        Assert.Equal("Stopped after 1 page. The page was kept. Undo takes it back.", f.Vm.Message.Text);
        Assert.Equal("Make searchable", tab.Session.UndoLabel);
        Assert.True(tab.Undo());
        Assert.False(tab.Session.CanUndo);
        Assert.False(PdfOcrLayer.Has(tab.Document, tab.Document.Pages[0]));
    }

    [Fact]
    public async Task ACancelAfterPagesWithoutWordsChangesNothingAndSaysNothing()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 3);
        var recognizer = new FakeRecognizer { Words = [] };
        int reads = 0;
        recognizer.OnRead = () =>
        {
            if (++reads == 2) f.Vm.CancelBusy();
        };

        await Make(tab, f, recognizer, new("en-US", OcrWork.Dpi, OcrExisting.Skip, [0, 1, 2], Force: true));

        Assert.Equal("Cancelled.", f.Vm.StatusFull);
        Assert.Null(f.Vm.Message);
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public async Task ACancelOnTheFirstPageLeavesTheDocumentAsItWas()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 3);
        var recognizer = new FakeRecognizer { OnRead = () => f.Vm.CancelBusy() };

        var result = await Make(tab, f, recognizer, new("en-US", OcrWork.Dpi, OcrExisting.Skip, [0, 1, 2], Force: true));

        Assert.Null(result);
        Assert.Equal("Cancelled.", f.Vm.StatusFull);
        Assert.Null(f.Vm.Message);
        Assert.False(tab.Session.CanUndo);
        Assert.False(PdfOcrLayer.Has(tab.Document, tab.Document.Pages[0]));
    }

    [Fact]
    public async Task ALanguageWindowsLacksIsShownAsAProblem()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f);
        var recognizer = new FakeRecognizer { Fails = new InvalidOperationException("Windows cannot read xx text yet.") };

        var result = await Make(tab, f, recognizer, All(language: "xx"));

        Assert.Null(result);
        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("Language not available", f.Vm.Message.Title);
        Assert.Contains("xx", f.Vm.Message.Text);
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public async Task TheLanguageWithMostWordsWritesTheLayer()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f);
        var recognizer = new FakeRecognizer();
        recognizer.ByLanguage["en-US"] = ["a", "b"];
        recognizer.ByLanguage["tr"] = ["a", "b", "c", "d", "e"];

        await OcrWork.MakeSearchableAsync(tab, f.Vm, recognizer, All(), ["en-US", "tr"]);

        Assert.Equal(5, Words(tab).Count());
        Assert.Equal(["en-US", "tr", "en-US", "tr"], recognizer.Languages);
        Assert.Equal("en-US", PdfOcrLayer.Language(tab.Document, tab.Document.Pages[0]));
    }

    [Fact]
    public async Task OneLanguageReadsEachPageOnce()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f);
        var recognizer = new FakeRecognizer();

        await Make(tab, f, recognizer, All());

        Assert.Equal(["en-US", "en-US"], recognizer.Languages);
    }

    [Fact]
    public async Task PagesThatCouldNotBeDrawnAreSaid()
    {
        using var f = new ViewModelFixture { Draws = false };
        var tab = await Open(f);

        var result = await Make(tab, f, new FakeRecognizer(), All());

        Assert.Equal(2, result!.NotRendered);
        Assert.False(result.Committed);
        Assert.Equal("Not every page was read", f.Vm.Message!.Title);
        Assert.Equal("2 pages could not be drawn.", f.Vm.Message.Text);
    }

    [Fact]
    public async Task PagesWithoutWordsAreSaidAndNothingIsCommitted()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);

        await Make(tab, f, new FakeRecognizer { Words = [] }, All());

        Assert.StartsWith("No text found on 1 page. Check the language.", f.Vm.Message!.Text);
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public async Task PagesWithoutWordsAreNotToldToRotate()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);

        await Make(tab, f, new FakeRecognizer { Words = [] }, All());

        Assert.DoesNotContain("sideways", f.Vm.Message!.Text);
    }

    private static PdfRgbaImage Landscape(bool ink)
    {
        var rgba = new byte[6 * 4 * 4];
        Array.Fill(rgba, (byte)255);
        if (ink) for (int i = 0; i < 12; i++) rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = 0;
        return new PdfRgbaImage(6, 4, rgba);
    }

    [Fact]
    public async Task ASidewaysPageIsTurnedUprightAndGetsALayer()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        ((FakeRenderer)tab.Renderer).Image = Landscape(ink: true);
        var recognizer = new FakeRecognizer { PortraitOnly = true, Words = ["alpha", "beta", "gamma"] };

        var result = await Make(tab, f, recognizer, All());

        Assert.Equal(1, result!.Added);
        Assert.Equal(90, tab.Document.Pages[0].Rotate);
        Assert.True(PdfOcrLayer.Has(tab.Document, tab.Document.Pages[0]));
        Assert.Equal(["alpha", "beta", "gamma"], Words(tab));
        Assert.Equal("Pages turned", f.Vm.Message!.Title);
        Assert.Equal("1 page was turned upright.", f.Vm.Message.Text);
    }

    [Fact]
    public async Task TheWordsOfATurnedPageLieOnThePageInItsNewShape()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        ((FakeRenderer)tab.Renderer).Image = Landscape(ink: true);

        await Make(tab, f, new FakeRecognizer { PortraitOnly = true, Words = ["alpha", "beta", "gamma"] }, All());

        var geometry = new PageGeometry(tab.Document.Pages[0]);
        var boxes = PdfOcrLayer.Words(tab.Document, tab.Document.Pages[0]).Select(w => w.Box).ToList();
        Assert.Equal(3, boxes.Count);
        Assert.All(boxes, b => Assert.InRange(b.X + b.Width, geometry.Width - 1, geometry.Width + 1));
        Assert.All(boxes, b => Assert.InRange(b.Y + b.Height, 0, geometry.Height + 1));
    }

    [Fact]
    public async Task UndoPutsTheTurnAndTheLayerBackTogether()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        ((FakeRenderer)tab.Renderer).Image = Landscape(ink: true);

        await Make(tab, f, new FakeRecognizer { PortraitOnly = true, Words = ["alpha", "beta", "gamma"] }, All());
        Assert.True(tab.Undo());

        Assert.Equal(0, tab.Document.Pages[0].Rotate);
        Assert.False(PdfOcrLayer.Has(tab.Document, tab.Document.Pages[0]));
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public async Task ABlankPageIsReadOnlyOnce()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        ((FakeRenderer)tab.Renderer).Image = Landscape(ink: false);
        var recognizer = new FakeRecognizer { PortraitOnly = true, Words = ["alpha", "beta", "gamma"] };

        var result = await Make(tab, f, recognizer, All());

        Assert.Equal(1, result!.NoWords);
        Assert.Single(recognizer.Languages);
        Assert.Equal(0, tab.Document.Pages[0].Rotate);
    }

    [Fact]
    public async Task ATurnedReadWithTooFewWordsIsNotTaken()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        ((FakeRenderer)tab.Renderer).Image = Landscape(ink: true);

        await Make(tab, f, new FakeRecognizer { PortraitOnly = true, Words = ["alpha", "beta", "gamma"] }, All());
        Assert.Equal(90, tab.Document.Pages[0].Rotate);
        Assert.True(tab.Undo());

        await Make(tab, f, new FakeRecognizer { PortraitOnly = true, Words = ["alpha", "beta"] }, All());
        Assert.Equal(0, tab.Document.Pages[0].Rotate);
        Assert.False(PdfOcrLayer.Has(tab.Document, tab.Document.Pages[0]));
    }

    [Fact]
    public async Task NothingToDoIsSaidInTheStatus()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);

        await Make(tab, f, new FakeRecognizer(), new("en-US", OcrWork.Dpi, OcrExisting.Skip, [0]));

        Assert.Equal("No pages need text recognition.", f.Vm.StatusFull);
    }

    [Fact]
    public async Task RemovingTakesTheLayerOffOnlyWhereItIs()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 2);
        await Make(tab, f, new FakeRecognizer(), new("en-US", OcrWork.Dpi, OcrExisting.Skip, [0], Force: true));

        int removed = OcrWork.Remove(tab, [0, 1]);

        Assert.Equal(1, removed);
        Assert.False(PdfOcrLayer.Has(tab.Document, tab.Document.Pages[0]));
        Assert.Equal("Remove text layer", tab.Session.UndoLabel);
        Assert.Equal(0, OcrWork.Remove(tab, [0, 1]));
    }

    [Fact]
    public async Task ACorrectionChangesTheWordAndUndoRestoresIt()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        await Make(tab, f, new FakeRecognizer(), All());

        OcrWork.Correct(tab, 0, 1, "gamma");

        Assert.Equal(["alpha", "gamma"], Words(tab));
        Assert.Equal("Correct word", tab.Session.UndoLabel);
        tab.Undo();
        Assert.Equal(["alpha", "beta"], Words(tab));
    }

    [Fact]
    public async Task AnEmptyCorrectionRemovesTheWord()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        await Make(tab, f, new FakeRecognizer(), All());

        OcrWork.Correct(tab, 0, 0, "");

        Assert.Equal(["beta"], Words(tab));
    }

    [Fact]
    public async Task ThePageCountReachesTheBusyBar()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f);
        var seen = new List<string>();
        var recognizer = new FakeRecognizer { OnRead = () => seen.Add(f.Vm.BusyText) };

        await Make(tab, f, recognizer, All());

        Assert.Equal(["Reading pages", "Reading page 1 of 2"], seen);
    }

    [Fact]
    public async Task ADocumentThatChangedMidRunIsLeftAloneAndSaid()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f);
        bool changed = false;
        var recognizer = new FakeRecognizer
        {
            OnRead = () =>
            {
                if (changed) return;
                changed = true;
                Pdfs.Retitle(tab.Session, "Other");
                tab.Commit("Retitle");
            },
        };

        var result = await Make(tab, f, recognizer, All());

        Assert.Null(result);
        Assert.Equal("The file changed", f.Vm.Message!.Title);
        Assert.Equal("Retitle", tab.Session.UndoLabel);
        Assert.False(PdfOcrLayer.Has(tab.Document, tab.Document.Pages[0]));
    }

    [Fact]
    public async Task ReplacingWithNoWordsSaysTheOldTextWasRemoved()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        await Make(tab, f, new FakeRecognizer(), All());

        await Make(tab, f, new FakeRecognizer { Words = [] }, All(OcrExisting.Replace));

        Assert.Contains("Text read earlier on those pages was removed.", f.Vm.Message!.Text);
        Assert.Empty(Words(tab));
        Assert.True(tab.Undo());
        Assert.Equal(["alpha", "beta"], Words(tab));
    }

    [Fact]
    public async Task APageWithNoLayerBeforeGetsNoSuchSentence()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);

        await Make(tab, f, new FakeRecognizer { Words = [] }, All(OcrExisting.Replace));

        Assert.DoesNotContain("removed", f.Vm.Message!.Text);
    }

    [Fact]
    public async Task ACorrectionThatChangesNothingAddsNoStep()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        await Make(tab, f, new FakeRecognizer(), All());
        int revision = tab.Revision;

        Assert.False(OcrWork.Correct(tab, 0, 1, "beta"));

        Assert.Equal(revision, tab.Revision);
        Assert.Equal("Make searchable", tab.Session.UndoLabel);
    }

    [Fact]
    public async Task RemovingIgnoresPagesThePanelStillListsAfterTheyWereDeleted()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f, 1);
        await Make(tab, f, new FakeRecognizer(), All());

        Assert.Equal(1, OcrWork.Remove(tab, [0, 7]));
    }

    [Fact]
    public async Task AFileThatForbidsChangesIsRefused()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("r.pdf", Pdfs.Restricted(PdfPermissions.Print)));
        var tab = f.Vm.ActiveDocument!;

        bool cleared = OcrWork.Cleared(tab, f.Vm, () => throw new InvalidOperationException());

        Assert.False(cleared);
        Assert.True(f.Vm.Message!.IsError);
        Assert.Equal("This file cannot be changed", f.Vm.Message.Title);
    }

    [Fact]
    public async Task AFileThatMayBeChangedIsClear()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f);

        Assert.True(OcrWork.Cleared(tab, f.Vm, () => { }));
        Assert.Null(f.Vm.Message);
    }

    [Fact]
    public async Task ASignedFileAsksFirstAndGoesOnOnYes()
    {
        using var f = new ViewModelFixture();
        var tab = await Open(f);
        tab.Document.Catalog["Perms"] = new PdfDictionary { ["UR3"] = new PdfDictionary() };
        bool went = false;

        bool cleared = OcrWork.Cleared(tab, f.Vm, () => went = true);

        Assert.False(cleared);
        Assert.False(went);
        Assert.Equal("Check before going on", f.Vm.Message!.Title);
        Assert.Contains("signed", f.Vm.Message.Text);
        f.Vm.Message.Action!.Run();
        Assert.True(went);
    }
}

