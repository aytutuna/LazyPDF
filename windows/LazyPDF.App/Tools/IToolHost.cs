using System.Security.Cryptography.X509Certificates;
using System.Windows;
using LazyPDF.App.Documents;

namespace LazyPDF.App.Tools;

/// <summary>What a tool panel can ask of the window besides the document and the viewer: the busy bar, the info bar, the status line and new tabs.</summary>
public interface IToolHost
{
    /// <summary>Runs <paramref name="work"/> with the busy bar showing <paramref name="text"/> and a Cancel that ends it through the token.</summary>
    Task RunBusyAsync(string text, Func<CancellationToken, Task> work);

    /// <summary>Changes the text of the busy bar while <see cref="RunBusyAsync"/> runs, for a step count; does nothing when it does not.</summary>
    void SetBusyText(string text) { }

    /// <summary>Shows <paramref name="view"/> on the stage in place of the viewer, until it is called again with null. Only a tool that is attached may hold it, and it lets go when it is detached.</summary>
    void HoldStage(UIElement? view) { }

    void ShowProblem(Problem problem);

    void ShowNotice(string title, string text, NoticeAction? action = null);

    void SetStatus(string sentence);

    /// <summary>Opens a file in a tab, or shows the tab it is already in.</summary>
    Task OpenAsync(string path);

    /// <summary>Opens PDF bytes as a new document with unsaved changes and no file, so saving asks for a name: the result of Combine, Compare, Export or Create. False when no tab could be made, with the problem already shown.</summary>
    Task<bool> OpenNewAsync(byte[] pdf, string title);

    /// <summary>As above, for encrypted bytes: the password or certificate that opens them is kept for the tab, so nothing is asked again.</summary>
    Task<bool> OpenNewAsync(byte[] pdf, string title, string? password, X509Certificate2? certificate) => OpenNewAsync(pdf, title);

    /// <summary>Opens the tool with this id on the document in view, as picking it from the tool strip would, but never closes it when it is open already.</summary>
    void OpenTool(string id) { }

    /// <summary>Opens the Certificates tool with the empty signature field of that name chosen as the place to sign.</summary>
    void OpenSigning(string field) { }

    /// <summary>The field <see cref="OpenSigning"/> named, once: the tool asks for it when it is shown.</summary>
    string? TakeSigningField() => null;

    /// <summary>Reads the tab's file from disk again and puts it in the tab's place, after a tool wrote the file.</summary>
    Task ReloadAsync(DocumentTab tab);

    /// <summary>As above; false when the tab was not replaced, and the info bar says why.</summary>
    async Task<bool> TryReloadAsync(DocumentTab tab)
    {
        await ReloadAsync(tab);
        return true;
    }
}
