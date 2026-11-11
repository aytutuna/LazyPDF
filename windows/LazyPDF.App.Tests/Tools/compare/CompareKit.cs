using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Compare;
using LazyPDF.Core;

namespace LazyPDF.App.Tests;

/// <summary>Files and renderers for the comparison tests.</summary>
internal static class CompareKit
{
    public static byte[] Before() => Pdfs.Text(2);

    /// <summary>The same two pages with a word added on each, a form field and a new title.</summary>
    public static byte[] After()
    {
        var session = PdfEditSession.Open(Pdfs.Text(2, "Hello from the other tests."));
        PdfForm.Read(session.Document).AddField(new FieldSpec(FieldKind.Text, "name", 0, new PdfRect(100, 400, 300, 420)) { Value = "Ann" });
        Pdfs.Retitle(session, "Second");
        session.Commit("Edit");
        return session.Current.ToArray();
    }

    public static CompareSession Session(byte[] before, byte[] after, Func<IDocumentRenderer>? renderers = null)
    {
        var session = new CompareSession(new Side(before, "old.pdf", null, null), new Side(after, "new.pdf", null, null), renderers ?? (() => new FakeRenderer()));
        session.Compare(new CompareOptions(), byPixels: false, CancellationToken.None);
        return session;
    }

    /// <summary>The old file draws blank pages, the new one pages with a black block.</summary>
    public static byte[] Locked(string userPassword)
    {
        var document = PdfDocument.Open(Pdfs.Text(2, "Hello from the other tests."));
        var security = PdfSecurity.Create(userPassword, "owner", PdfPermissions.All, PdfCryptStrength.Aes256, document.FirstId ?? []);
        return document.SaveRewrite(new PdfSaveOptions(Security: security));
    }

    /// <summary>The old file draws blank pages, the new one a page of 200 specks and a page with one block.</summary>
    public static Func<IDocumentRenderer> Speckled()
    {
        int made = 0;
        return () => new SpeckledRenderer(made++ > 0);
    }

    public static Func<IDocumentRenderer> Painted()
    {
        int made = 0;
        return () => new PaintedRenderer(made++ > 0);
    }
}

internal sealed class PaintedRenderer(bool block) : IDocumentRenderer
{
    public bool Load(PdfEditSession session, string? password) => true;

    public (double Width, double Height) PageSize(int pageIndex) => (200, 300);

    public PdfRgbaImage? Render(int pageIndex, double dpi)
    {
        var rgba = new byte[200 * 300 * 4];
        Array.Fill(rgba, (byte)255);
        if (block)
        {
            for (int y = 100; y < 140; y++)
            {
                for (int x = 60; x < 120; x++) Array.Fill(rgba, (byte)0, (y * 200 + x) * 4, 3);
            }
        }
        return new PdfRgbaImage(200, 300, rgba);
    }

    public void Dispose()
    {
    }
}

/// <summary>A host that cancels whatever it is asked to run, as the Cancel button does.</summary>
internal sealed class CancellingHost : IToolHost
{
    public async Task RunBusyAsync(string text, Func<CancellationToken, Task> work)
    {
        using var source = new CancellationTokenSource();
        source.Cancel();
        try
        {
            await work(source.Token);
        }
        catch (OperationCanceledException)
        {
        }
    }

    public void ShowProblem(Problem problem)
    {
    }

    public void ShowNotice(string title, string text, NoticeAction? action = null)
    {
    }

    public void SetStatus(string sentence)
    {
    }

    public Task OpenAsync(string path) => Task.CompletedTask;

    public Task<bool> OpenNewAsync(byte[] pdf, string title)
    {
        Opened++;
        return Task.FromResult(true);
    }

    public Task ReloadAsync(DocumentTab tab) => Task.CompletedTask;

    public int Opened { get; private set; }
}

internal sealed class SpeckledRenderer(bool specks) : IDocumentRenderer
{
    public bool Load(PdfEditSession session, string? password) => true;

    public (double Width, double Height) PageSize(int pageIndex) => (200, 300);

    public PdfRgbaImage? Render(int pageIndex, double dpi)
    {
        var rgba = new byte[200 * 300 * 4];
        Array.Fill(rgba, (byte)255);
        for (int y = 0; specks && y < 300; y++)
        {
            for (int x = 0; x < 200; x++)
            {
                bool ink = pageIndex == 0 ? x % 12 < 4 && y % 12 < 4 && x < 240 && y < 120 : x is >= 60 and < 120 && y is >= 100 and < 140;
                if (ink) Array.Fill(rgba, (byte)0, (y * 200 + x) * 4, 3);
            }
        }
        return new PdfRgbaImage(200, 300, rgba);
    }

    public void Dispose()
    {
    }
}
