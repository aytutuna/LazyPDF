using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Comment;

/// <summary>What the comment panels share: whether a long change to the file is running, and the commit that tolerates a file that will not take it.</summary>
public static class MarkWork
{
    /// <summary>True while import, flatten or attach changes the document off the UI thread; nothing else may touch it meanwhile.</summary>
    public static bool Running { get; set; }

    /// <summary>What to tell before marks are added to a signed file; null when the file is not signed.</summary>
    public static string? Caution(PdfDocument document) =>
        !document.IsSigned ? null
        : document.IsCertified ? Loc.T("This file is certified, so changing it makes viewers report it as altered.")
        : Loc.T("This file is signed, so changing it breaks the signatures.");

    /// <summary>Holds a change to a signed file back until the user goes on anyway; true when it was held back.</summary>
    public static bool Cautioned(DocumentTab tab, IToolHost host, Action again)
    {
        if (Caution(tab.Document) is not { } warning) return false;
        host.ShowNotice(Loc.T("Check before going on"), warning, new NoticeAction(Loc.T("Go on anyway"), again));
        return true;
    }

    /// <summary>Commits the change; a file that does not read back with it is put back as it was, with a problem shown.</summary>
    public static bool Commit(DocumentTab tab, IToolHost host, string label)
    {
        try
        {
            return tab.Commit(label);
        }
        catch (Exception error) when (error is PdfReadException or InvalidOperationException or ArgumentException)
        {
            tab.Session.Discard();
            host.ShowProblem(new Problem(Loc.T("Change not kept"), Loc.T("The file would not read back with that change. Save a copy and try again.")));
            return false;
        }
    }
}
