using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Compare;

/// <param name="Path">The other file; null when <paramref name="Version"/> or <paramref name="OtherTab"/> is given.</param>
/// <param name="Version">An earlier state of the open file.</param>
/// <param name="FileIsOlder">With <paramref name="Path"/>, the open file is the old side and the other file the new one.</param>
/// <param name="Password">Opens the other file; the open file's own password is tried when null.</param>
/// <param name="Certificate">Opens the other file when it is encrypted for recipients.</param>
/// <param name="PixelDpi">The detail a pixel comparison draws the pages at.</param>
/// <param name="OtherTab">Another open document, compared as it is now, unsaved edits included.</param>
internal sealed record CompareRequest(string? Path, PdfVersion? Version, bool FileIsOlder, CompareOptions Options, bool ByPixels,
    string? Password = null, X509Certificate2? Certificate = null, double PixelDpi = 96, DocumentTab? OtherTab = null);

/// <summary>The long parts of the tool: running a comparison and writing its report, with the busy bar and the messages.</summary>
internal sealed class CompareFlow(IToolHost host, Func<IDocumentRenderer> renderers, IFontSource fonts)
{
    /// <summary>What the other file of the last run needs to be opened; null when it opened or was not the reason the run failed.</summary>
    public PdfReadProblem? Locked { get; private set; }

    /// <summary>The finished comparison, or null when it was cancelled or a file could not be read.</summary>
    public async Task<CompareSession?> RunAsync(DocumentTab tab, CompareRequest request)
    {
        Locked = null;
        if (request.OtherTab is { } gone && !host.OpenDocuments.Contains(gone))
        {
            host.ShowProblem(new Problem(Loc.T("File closed"), Loc.T("That file was closed. Pick another.")));
            return null;
        }
        var open = Side.Of(tab);
        var earlier = request.Version is { } version ? Side.Of(tab, version) : request.OtherTab is { } otherTab ? Side.Of(otherTab) : null;
        string? password = request.Password ?? tab.Password;
        CompareSession? made = null;
        try
        {
            await host.RunBusyAsync(Loc.T("Comparing files"), token => Task.Run(() =>
            {
                var other = earlier ?? Side.Of(request.Path!, password, request.Certificate);
                var (before, after) = request.Version is not null ? (other, open) : request.FileIsOlder ? (open, other) : (other, open);
                var session = new CompareSession(before, after, renderers);
                try
                {
                    session.Compare(request.Options, request.ByPixels, request.PixelDpi, token);
                }
                catch
                {
                    session.Dispose();
                    throw;
                }
                made = session;
            }, token));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or PdfReadException)
        {
            if (e is PdfReadException { Problem: PdfReadProblem.PasswordRequired or PdfReadProblem.CertificateRequired } locked && request.Path is not null)
            {
                Locked = locked.Problem;
                return null;
            }
            host.ShowProblem(Problems.Open(e, request.Path is null ? (request.OtherTab ?? tab).Title : System.IO.Path.GetFileName(request.Path)));
            return null;
        }
        if (made is not null) host.SetStatus(Headline(made, made.Rows(Parts.All).Count));
        return made;
    }

    public async Task WriteReportAsync(CompareSession session, Parts parts)
    {
        if (!session.CanReport)
        {
            host.ShowProblem(new Problem(Loc.T("Report not allowed"), Loc.T("{0} limits what readers may do. Open it with its owner password to write a report.", session.New.Title)));
            return;
        }
        bool filtered = !session.ByPixels && parts != Parts.All;
        if (filtered && ChangeParts.Only(session.Result!, parts).IsIdentical && !session.Result!.IsIdentical)
        {
            host.ShowProblem(new Problem(Loc.T("Nothing to report"), Loc.T("No difference matches the kinds switched on. Switch on more kinds under Show.")));
            return;
        }
        byte[]? report = null;
        try
        {
            await host.RunBusyAsync(Loc.T("Writing report"), async token =>
            {
                var written = await Task.Run(() => session.Report(parts, fonts));
                token.ThrowIfCancellationRequested();
                report = written;
            });
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            host.ShowProblem(new Problem(Loc.T("Report not written"), Loc.T("The report could not be built from this comparison. Run the comparison again.")));
            System.Diagnostics.Trace.TraceError(e.ToString());
            return;
        }
        if (report is null) return;
        string stem = System.IO.Path.GetFileNameWithoutExtension(session.New.Title);
        string title = filtered ? Loc.T("{0}, filtered - {1}.pdf", CompareText.Title, stem) : $"{CompareText.Title} - {stem}.pdf";
        await host.OpenNewAsync(report, title, session.New.Password, session.New.Certificate);
    }

    /// <summary>The states of the file that differ from the one open: a version that ends where the file ends is the file itself.</summary>
    public static IReadOnlyList<PdfVersion> Earlier(PdfEditSession session) => [.. session.Versions.Where(v => v.End < session.Current.Length)];

    /// <summary>What the panel says over the list: how many differences are shown.</summary>
    public static string Headline(CompareSession session, int shown)
    {
        if (shown > 0) return session.ByPixels ? Loc.Plural(shown, "{0} area differs", "{0} areas differ") : CompareText.ChangeCount(shown);
        if (session.ByPixels) return session.Looked == 0 && session.Undrawn > 0 ? Loc.T("Pages could not be drawn.") : CompareText.NoDifferences;
        return session.Result!.IsIdentical ? CompareText.NoDifferences : Loc.T("Nothing to show with these filters.");
    }

    /// <summary>A line under the headline: the words added and removed, or what a pixel comparison left out; null when there is nothing to add.</summary>
    public static string? Note(CompareSession session)
    {
        if (session.ByPixels)
        {
            if (session.PixelCapped) return Loc.T("Only the first {0} places are listed.", CompareSession.MaxPixelRows);
            return session.Undrawn > 0 ? Loc.Plural(session.Undrawn, "{0} page could not be drawn.", "{0} pages could not be drawn.") : null;
        }
        var summary = session.Result!.Summary;
        return summary.WordsAdded + summary.WordsRemoved == 0 ? null : Loc.T("Words: {0} added, {1} removed", summary.WordsAdded, summary.WordsRemoved);
    }
}
