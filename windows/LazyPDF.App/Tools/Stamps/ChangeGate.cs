using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Stamps;

/// <summary>What stands before a change that is not the tool's pinned action: the file's permissions, its signatures, and a failure that must not end the app.</summary>
public static class ChangeGate
{
    /// <summary>Why the file may not be changed; null when it may.</summary>
    public static Problem? Refusal(PdfDocument document, string? file = null) =>
        document.Security is { OpenedAsOwner: false } security && !security.Permissions.HasFlag(PdfPermissions.Modify)
            ? Problems.Restricted(file)
            : null;

    /// <summary>Runs <paramref name="run"/> unless the file forbids it; a signed file asks first. A change to a file that is not the one in view passes its <paramref name="file"/> name, so the notice, which is shown over the active tab, says which file it is about.</summary>
    public static async Task RunAsync(DocumentTab tab, IToolHost host, string name, Func<Task> run, string? file = null)
    {
        if (Refusal(tab.Document, file) is { } problem)
        {
            host.ShowProblem(problem);
            return;
        }
        if (tab.Document.IsSigned)
        {
            string warning = (tab.Document.IsCertified, file) switch
            {
                (true, null) => Loc.T("This file is certified, so changing it makes viewers report it as altered."),
                (false, null) => Loc.T("This file is signed, so changing it breaks the signatures."),
                (true, _) => Loc.T("{0} is certified, so changing it makes viewers report it as altered.", file),
                (false, _) => Loc.T("{0} is signed, so changing it breaks the signatures.", file),
            };
            host.ShowNotice(Loc.T("Check before going on"), warning, new NoticeAction(Loc.T("Go on anyway"), () => Start(host, name, run, file)));
            return;
        }
        await Guarded(host, name, run, file);
    }

    private static async void Start(IToolHost host, string name, Func<Task> run, string? file) => await Guarded(host, name, run, file);

    private static async Task Guarded(IToolHost host, string name, Func<Task> run, string? file)
    {
        try
        {
            await run();
        }
        catch (PdfPermissionException)
        {
            host.ShowProblem(Problems.Restricted(file));
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            host.ShowProblem(new Problem(Loc.T("Something went wrong"), Loc.T("{0} could not be finished. If part of it was done, Undo takes it back.", name)));
            System.Diagnostics.Trace.TraceError(error.ToString());
        }
    }
}
