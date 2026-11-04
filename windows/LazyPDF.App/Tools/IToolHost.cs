using LazyPDF.App.Documents;

namespace LazyPDF.App.Tools;

/// <summary>What a tool panel can ask of the window besides the document and the viewer: the busy bar, the info bar, the status line and new tabs.</summary>
public interface IToolHost
{
    /// <summary>Runs <paramref name="work"/> with the busy bar showing <paramref name="text"/> and a Cancel that ends it through the token.</summary>
    Task RunBusyAsync(string text, Func<CancellationToken, Task> work);

    void ShowProblem(Problem problem);

    void ShowNotice(string title, string text, NoticeAction? action = null);

    void SetStatus(string sentence);

    /// <summary>Opens a file in a tab, or shows the tab it is already in.</summary>
    Task OpenAsync(string path);

    /// <summary>Opens PDF bytes as a new document with unsaved changes and no file, so saving asks for a name: the result of Combine, Compare, Export or Create.</summary>
    Task OpenNewAsync(byte[] pdf, string title);
}
