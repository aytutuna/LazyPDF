using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>Pages copied into a new file leave the source's password and permissions behind, so the source decides whether that may happen.</summary>
internal static class CopyRules
{
    /// <summary>The file limits what its readers may do and was not opened with the owner's rights.</summary>
    public static bool Locked(PdfDocument document) => document.Security is { OpenedAsOwner: false, Permissions: not PdfPermissions.All };

    /// <summary>True, with the reason shown, when pages may not be copied out of <paramref name="document"/>.</summary>
    public static bool Refused(PdfDocument document, IToolHost host)
    {
        if (!Locked(document)) return false;
        host.ShowProblem(new Problem(Loc.T("File is protected"), Loc.T("Its owner limits what may be done with it. Open it with the owner password to copy pages out.")));
        return true;
    }

    public static string Unprotected => Loc.T("The copies are not password protected.");

    public static void NoteUnprotected(PdfDocument document, IToolHost host)
    {
        if (document.IsEncrypted) host.ShowNotice(Loc.T("Copy is not protected"), Unprotected);
    }
}
