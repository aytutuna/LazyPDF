// Comments to and from FDF and XFDF files, flattening, and the way long changes to the file are run.

using System.Windows;
using Microsoft.Win32;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Comment;

public partial class CommentPanel
{
    // Changes the open file off the UI thread, with the rest of the panel and the side panel held back meanwhile.
    // Anything but a clean finish (a stop, a failure, another tab) puts the file back as it was.
    private async Task<bool> WorkAsync(DocumentTab tab, IToolHost host, string text, Action<CancellationToken> work)
    {
        bool done = false;
        MarkWork.Running = true;
        UpdateEnabled();
        RaiseActionChanged();
        try
        {
            await host.RunBusyAsync(text, async ct =>
            {
                try
                {
                    await Task.Run(() =>
                    {
                        ct.ThrowIfCancellationRequested();
                        work(ct);
                    });
                    ct.ThrowIfCancellationRequested();
                    done = true;
                }
                catch
                {
                    tab.Session.Discard();
                    throw;
                }
            });
        }
        finally
        {
            MarkWork.Running = false;
            UpdateEnabled();
            RaiseActionChanged();
        }
        if (done && !ReferenceEquals(Tab, tab))
        {
            tab.Session.Discard();
            return false;
        }
        return done;
    }

    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host || !_allowed || MarkWork.Running) return;
        var dialog = new OpenFileDialog { Filter = Loc.T("Comment files") + "|*.fdf;*.xfdf" };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        string path = dialog.FileName;
        string name = Path.GetFileName(path);
        bool xfdf = Exchange.IsXfdf(path);
        try
        {
            byte[] data = await File.ReadAllBytesAsync(path);
            FdfImportResult? result = null;
            if (!ReferenceEquals(Tab, tab) || !await WorkAsync(tab, host, Loc.T("Importing comments"), _ => result = Exchange.Import(tab.Document, data, xfdf, _fonts))) return;
            if (result is not { Imported: > 0 })
            {
                tab.Session.Discard();
                host.ShowNotice(Loc.T("Nothing imported"), result?.Skipped > 0
                    ? Loc.T("The comments in {0} are already in this file or belong to other pages.", name)
                    : Loc.T("{0} has no comments for the pages of this file.", name));
                return;
            }
            if (!MarkWork.Commit(tab, host, Loc.T("Import comments"))) return;
            host.SetStatus(Loc.Plural(result.Imported, "Imported {0} comment.", "Imported {0} comments."));
            if (result.Skipped > 0 || result.WithoutAppearance > 0)
            {
                host.ShowNotice(Loc.T("Some comments left out"), Loc.T("{0} skipped as copies or for other pages. {1} without a drawing.", result.Skipped, result.WithoutAppearance));
            }
        }
        catch (PdfReadException)
        {
            host.ShowProblem(new Problem(Loc.T("Not a comment file"), Loc.T("{0} could not be read. Pick an FDF or XFDF file.", name)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(Problems.Open(error, name));
        }
    }

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host || MarkWork.Running) return;
        var dialog = new SaveFileDialog
        {
            Filter = Loc.T("FDF file") + "|*.fdf|" + Loc.T("XFDF file") + "|*.xfdf",
            DefaultExt = ".fdf",
            AddExtension = true,
            OverwritePrompt = true,
            FileName = Path.GetFileNameWithoutExtension(tab.Title),
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        string path = dialog.FileName;
        bool xfdf = Exchange.IsXfdf(path);
        // The export reads a copy of the file, so the open document is not touched while it runs.
        byte[] bytes = tab.Session.Current.ToArray();
        string? password = tab.Password;
        var certificate = tab.Certificate;
        string title = tab.Title;
        Exported? exported = null;
        try
        {
            await host.RunBusyAsync(Loc.T("Exporting comments"), async ct =>
            {
                var made = await Task.Run(() => Exchange.Export(Exchange.Open(bytes, password, certificate), title, xfdf));
                ct.ThrowIfCancellationRequested();
                exported = made;
            });
            if (exported is null) return;
            if (exported.Count == 0)
            {
                host.SetStatus(Loc.T("No comments to export."));
                return;
            }
            await File.WriteAllBytesAsync(path, exported.Data);
            host.SetStatus(Loc.T("Comments exported."));
            if (exported.Left > 0)
            {
                host.ShowNotice(Loc.T("Some content left out"), Loc.Plural(exported.Left, "{0} attachment or picture stamp is not in an XFDF file. Export as FDF to keep it.", "{0} attachments or picture stamps are not in an XFDF file. Export as FDF to keep them."));
            }
        }
        catch (PdfReadException)
        {
            host.ShowProblem(new Problem(Loc.T("Comments not exported"), Loc.T("The file could not be read for export. Save a copy and try again.")));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(new Problem(Loc.T("Not saved"), Loc.T("{0} could not be written. Check that the disk has room and try again.", Path.GetFileName(path))));
        }
    }

    private Task FlattenAsync()
    {
        if (Tab is not { } tab || Host is not { } host) return Task.CompletedTask;
        if (!tab.Document.IsSigned) return FlattenNowAsync(tab, host);
        host.ShowNotice(Loc.T("Check before going on"), Loc.T("This file is signed, so changing it breaks the signatures."), new NoticeAction(Loc.T("Go on anyway"), () =>
        {
            if (ReferenceEquals(Tab, tab)) _ = FlattenNowAsync(tab, host);
        }));
        return Task.CompletedTask;
    }

    private async Task FlattenNowAsync(DocumentTab tab, IToolHost host)
    {
        int burned = 0;
        try
        {
            if (!await WorkAsync(tab, host, Loc.T("Flattening comments"), ct => burned = Exchange.Flatten(tab.Document, ct))) return;
        }
        catch (Exception error) when (error is PdfReadException or InvalidOperationException)
        {
            host.ShowProblem(new Problem(Loc.T("Comments not flattened"), Loc.T("The pages could not be changed. Save a copy of the file and try again.")));
            return;
        }
        if (burned == 0)
        {
            tab.Session.Discard();
            host.SetStatus(Loc.T("Nothing to flatten."));
            return;
        }
        if (MarkWork.Commit(tab, host, Loc.T("Flatten comments"))) host.SetStatus(Loc.Plural(burned, "Flattened {0} mark.", "Flattened {0} marks."));
    }
}
