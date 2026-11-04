using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.EditContent;

internal static class Clearance
{
    /// <summary>Why the file may not be changed; null when it may.</summary>
    public static Problem? Refusal(PdfDocument document) =>
        document.Security is { OpenedAsOwner: false } security && !security.Permissions.HasFlag(PdfPermissions.Modify)
            ? new Problem(Loc.T("This file cannot be changed"), Loc.T("Its permissions do not allow it. Open it with the owner password."))
            : null;
}
