using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Optimize;

/// <summary>Where the result of Make smaller and Clean for sharing goes: a new tab, or over the file the tab was read from.</summary>
internal static class OutputWriter
{
    /// <summary>True, with the info bar saying why, when the file on disk is not the one the tab was read from and replacing it would drop the other version.</summary>
    public static bool Refuses(IToolHost host, DocumentTab tab, bool replace)
    {
        if (!replace || tab.Path is not { } path || !tab.ChangedOnDisk || !File.Exists(path)) return false;
        host.ShowProblem(new Problem(Loc.T("File changed"), Loc.T("{0} was changed by another program. Pick New file, or open that version first.", tab.Title)));
        return true;
    }

    /// <summary>
    /// False when the result was not delivered; the info bar says why and the open document is as it was.
    /// <paramref name="revision"/> is the one the bytes were made from.
    /// </summary>
    public static async Task<bool> DeliverAsync(IToolHost host, DocumentTab tab, int revision, byte[] bytes, bool replace, string newTitle)
    {
        if (tab.Revision != revision)
        {
            host.ShowProblem(new Problem(Loc.T("Document changed"), Loc.T("{0} changed while this ran. Run it again.", tab.Title)));
            return false;
        }
        if (!replace || tab.Path is not { } path)
        {
            await host.OpenNewAsync(bytes, newTitle, tab.Password, tab.Certificate);
            return true;
        }
        if (Refuses(host, tab, replace)) return false;
        try
        {
            string? password = tab.Password;
            var certificate = tab.Certificate;
            var source = tab.Document;
            await Task.Run(() => PdfFileSaver.Save(path, bytes, password, certificate, source, samePages: true));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or PdfReadException)
        {
            host.ShowProblem(Problems.Save(e, tab.Title));
            return false;
        }
        if (await host.TryReloadAsync(tab)) return true;
        host.ShowProblem(new Problem(Loc.T("File written, not shown"), Loc.T("{0} was saved but could not be read again. Open it from disk.", tab.Title)));
        return false;
    }
}
