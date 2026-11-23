using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;

namespace LazyPDF.App.Tests;

internal sealed class StageHost : IToolHost
{
    public UIElement? Stage { get; private set; }
    public List<Problem> Problems { get; } = [];
    public List<string> Opened { get; } = [];
    public List<string> Notices { get; } = [];
    public List<NoticeAction?> Actions { get; } = [];
    public string Status { get; private set; } = "";
    public List<DocumentTab> Documents { get; } = [];
    public CancellationTokenSource Cancel { get; set; } = new();

    public IReadOnlyList<DocumentTab> OpenDocuments => Documents;

    // The same catches as AppViewModel.RunBusyAsync, so a cancel or a refusal ends where it does in the app.
    public async Task RunBusyAsync(string text, Func<CancellationToken, Task> work)
    {
        try
        {
            await work(Cancel.Token);
        }
        catch (OperationCanceledException)
        {
            Status = "Canceled.";
        }
        catch (PdfPermissionException)
        {
            ShowProblem(LazyPDF.App.Documents.Problems.Restricted());
        }
    }

    public void HoldStage(UIElement? view) => Stage = view;

    public void ShowProblem(Problem problem) => Problems.Add(problem);

    public void ShowNotice(string title, string text, NoticeAction? action = null)
    {
        Notices.Add(title);
        Actions.Add(action);
    }

    public void SetStatus(string sentence) => Status = sentence;

    public Task OpenAsync(string path) => Task.CompletedTask;

    public Task<bool> OpenNewAsync(byte[] pdf, string title)
    {
        Opened.Add(title);
        return Task.FromResult(true);
    }

    public Task ReloadAsync(DocumentTab tab) => Task.CompletedTask;
}

internal sealed class Shown : IDisposable
{
    private readonly HwndSource _source;

    public Shown(DocumentTab tab, StageHost host)
    {
        View = new OrganizeView();
        var (viewer, _) = FakeViewer.Create();
        View.Attach(tab, viewer, host);
        _source = new HwndSource(new HwndSourceParameters("organize-test") { ParentWindow = new IntPtr(-3), Width = 900, Height = 600 }) { RootVisual = View };
        Layout();
    }

    public OrganizeView View { get; }

    public ListBox Grid => (ListBox)View.FindName("Thumbs");

    public Slider Slider => (Slider)View.FindName("TileSize");

    public List<PageCell> Cells => (List<PageCell>)Grid.ItemsSource;

    public Button Button(string name) => (Button)View.FindName(name);

    public void Layout()
    {
        View.Measure(new Size(900, 600));
        View.Arrange(new Rect(0, 0, 900, 600));
        View.UpdateLayout();
    }

    public void Select(params int[] pages)
    {
        Grid.SelectedItems.Clear();
        foreach (int page in pages) Grid.SelectedItems.Add(Cells[page]);
    }

    public void Click(string name) => Button(name).RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

    public void Dispose()
    {
        View.Detach();
        _source.Dispose();
    }
}

internal static class PagesKit
{
    public static DocumentTab Open(int pages = 6, string title = "a.pdf") =>
        new(PdfEditSession.Open(Pdfs.Text(pages)), new FakeRenderer(), null, title);

    public static string TextOf(DocumentTab tab, int page) =>
        System.Text.Encoding.Latin1.GetString(tab.Document.Pages[page].Contents());

    public static string Hex(string text) => Convert.ToHexString(System.Text.Encoding.Latin1.GetBytes(text));

    public static List<string> Order(DocumentTab tab) => [.. Enumerable.Range(0, tab.PageCount).Select(i => TextOf(tab, i))];

    // Drag arguments need a constructor WPF keeps to itself; the point is in the target's own space.
    public static DragEventArgs DragArgs(RoutedEvent routed, IDataObject data, UIElement target, Point at)
    {
        var make = typeof(DragEventArgs).GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single();
        var e = (DragEventArgs)make.Invoke([data, DragDropKeyStates.None, DragDropEffects.Move | DragDropEffects.Copy, target, at]);
        e.RoutedEvent = routed;
        e.Source = target;
        return e;
    }
}
