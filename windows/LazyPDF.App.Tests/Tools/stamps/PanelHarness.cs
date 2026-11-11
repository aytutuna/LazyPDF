using System.Reflection;
using System.Windows;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tests;

// Tests run on one STA thread that owns the application and its styles, so panels can be built and driven the way the window does.
// WPF allows one application per process, so it is made once and lives until the run ends.
internal static class Sta
{
    private static readonly Lazy<Dispatcher> Ui = new(Start);

    private static Dispatcher Start()
    {
        var ready = new TaskCompletionSource<Dispatcher>();
        var thread = new Thread(() =>
        {
            LazyPDF.App.App.Unattended = true;
            var app = new LazyPDF.App.App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            // The application has queued its start, which opens the window named by StartupUri. InitializeComponent
            // sets that name, so it runs after the start and no window is opened.
            app.Dispatcher.InvokeAsync(() =>
            {
                app.InitializeComponent();
                ready.SetResult(app.Dispatcher);
            });
            Dispatcher.Run();
        })
        { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return ready.Task.Result;
    }

    public static async Task Run(Func<Task> test) => await await Ui.Value.InvokeAsync(test);

    public static async Task Until(Func<bool> done)
    {
        for (int i = 0; i < 400 && !done(); i++) await Task.Delay(25);
        if (!done()) throw new TimeoutException();
    }
}

internal sealed class RecordingHost : IToolHost
{
    public List<Problem> Problems { get; } = [];
    public List<string> Notices { get; } = [];
    public List<NoticeAction?> Actions { get; } = [];
    public string Status { get; private set; } = "";

    /// <summary>Runs before the work starts, for a test that changes the document under it.</summary>
    public Action? Before { get; set; }

    public bool Cancelled { get; set; }

    public async Task RunBusyAsync(string text, Func<CancellationToken, Task> work)
    {
        Before?.Invoke();
        using var source = new CancellationTokenSource();
        if (Cancelled) source.Cancel();
        try
        {
            await work(source.Token);
        }
        catch (OperationCanceledException)
        {
            Status = "Cancelled.";
        }
    }

    public void ShowProblem(Problem problem) => Problems.Add(problem);

    public void ShowNotice(string title, string text, NoticeAction? action = null)
    {
        Notices.Add(title);
        Actions.Add(action);
    }

    public void SetStatus(string sentence) => Status = sentence;

    public Task OpenAsync(string path) => Task.CompletedTask;

    public Task<bool> OpenNewAsync(byte[] pdf, string title) => Task.FromResult(true);

    public Task ReloadAsync(DocumentTab tab) => Task.CompletedTask;
}

// A viewer that shows page 0 at 200 x 300 and keeps what is put on its overlay.
public class FakeViewer : DispatchProxy
{
    public PageOverlay Overlay { get; } = new(0, new Size(200, 300));

    public FrameworkElement View { get; } = new();

    public ViewerSearch? Search { get; private set; }

    internal static IDocumentViewer Create(ViewerSearch search)
    {
        var viewer = Create<IDocumentViewer, FakeViewer>();
        ((FakeViewer)(object)viewer).Search = search;
        return viewer;
    }

    internal static (IDocumentViewer Viewer, PageOverlay Overlay) Create()
    {
        var viewer = Create<IDocumentViewer, FakeViewer>();
        return (viewer, ((FakeViewer)(object)viewer).Overlay);
    }

    protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
    {
        "get_VisiblePages" => new[] { 0 },
        "PageSize" => new Size(200, 300),
        "Overlay" => Overlay,
        "get_View" => View,
        "get_Search" => Search,
        _ when method.ReturnType == typeof(void) || !method.ReturnType.IsValueType => null,
        _ => Activator.CreateInstance(method.ReturnType),
    };
}
