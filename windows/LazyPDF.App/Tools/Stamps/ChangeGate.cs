using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Stamps;

/// <summary>What stands before a change that is not the tool's pinned action: the file's permissions, its signatures, and a failure that must not end the app.</summary>
public static class ChangeGate
{
    /// <summary>Why the file may not be changed; null when it may.</summary>
    public static Problem? Refusal(PdfDocument document) =>
        document.Security is { OpenedAsOwner: false } security && !security.Permissions.HasFlag(PdfPermissions.Modify)
            ? new Problem(Loc.T("This file cannot be changed"), Loc.T("Its permissions do not allow it. Open it with the owner password."))
            : null;

    /// <summary>Runs <paramref name="run"/> unless the file forbids it; a signed file asks first.</summary>
    public static async Task RunAsync(DocumentTab tab, IToolHost host, string name, Func<Task> run)
    {
        if (Refusal(tab.Document) is { } problem)
        {
            host.ShowProblem(problem);
            return;
        }
        if (tab.Document.IsSigned)
        {
            string warning = tab.Document.IsCertified
                ? Loc.T("This file is certified, so changing it makes viewers report it as altered.")
                : Loc.T("This file is signed, so changing it breaks the signatures.");
            host.ShowNotice(Loc.T("Check before going on"), warning, new NoticeAction(Loc.T("Go on anyway"), () => Start(host, name, run)));
            return;
        }
        await Guarded(host, name, run);
    }

    private static async void Start(IToolHost host, string name, Func<Task> run) => await Guarded(host, name, run);

    private static async Task Guarded(IToolHost host, string name, Func<Task> run)
    {
        try
        {
            await run();
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            host.ShowProblem(new Problem(Loc.T("Something went wrong"), Loc.T("{0} could not be finished. If part of it was done, Undo takes it back.", name)));
            System.Diagnostics.Trace.TraceError(error.ToString());
        }
    }
}
