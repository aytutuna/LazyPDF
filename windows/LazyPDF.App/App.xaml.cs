using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;

namespace LazyPDF.App;

public partial class App : Application
{
    /// <summary>One instance per user session.</summary>
    private const string InstanceMutexName = @"Local\LazyPDF.App";

    private Mutex? _instance;
    private InstanceChannel? _channel;

    /// <summary>
    /// Set by a host that builds the application without starting it, such as the tests: it then neither takes the
    /// single-instance mutex nor hands its arguments to a copy that is running.
    /// </summary>
    public static bool Unattended { get; set; }

    /// <summary>The files named on the command line; the main window takes them once it is open.</summary>
    public static IReadOnlyList<string> StartupFiles { get; private set; } = [];

    protected override void OnStartup(StartupEventArgs e)
    {
        EventManager.RegisterClassHandler(typeof(UIElement), AccessKeyManager.AccessKeyPressedEvent, new AccessKeyPressedEventHandler(RequireAlt));
        if (Unattended)
        {
            ThemeService.Initialize();
            base.OnStartup(e);
            return;
        }
        var files = FilesOf(e.Args);
        _instance = new Mutex(true, InstanceMutexName, out bool first);
        if (!first)
        {
            // The running instance opens the files (or just comes forward); this one has nothing more to do, unless
            // nobody answers: then it opens them itself rather than lose them.
            bool handed = InstanceChannel.Send(files);
            _instance.Dispose();
            _instance = null;
            if (handed)
            {
                Shutdown();
                return;
            }
        }
        StartupFiles = files;
        DispatcherUnhandledException += App_DispatcherUnhandledException;
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            System.Diagnostics.Trace.TraceError(args.Exception.ToString());
            args.SetObserved();
        };
        if (first) _channel = new InstanceChannel(Opened);
        if (AppPreferencesStore.Load().Language is ("en" or "tr") and var language)
        {
            // Only the texts change; number and date formats stay Windows'.
            var culture = CultureInfo.GetCultureInfo(language);
            CultureInfo.DefaultThreadCurrentUICulture = culture;
            Thread.CurrentThread.CurrentUICulture = culture;
        }
        // Apply the saved appearance before the first window is created.
        ThemeService.Initialize();
        base.OnStartup(e);
    }

    // WPF fires an access key on a plain letter while a button has focus; a stray key must not discard work.
    private static void RequireAlt(object sender, AccessKeyPressedEventArgs e)
    {
        if (Keyboard.FocusedElement is not Button || Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) return;
        e.Target = null;
        e.Handled = true;
    }

    // One failed handler should not take every open tab with it. Before the window is up there is nothing to show it in.
    private void App_DispatcherUnhandledException(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
    {
        System.Diagnostics.Trace.TraceError(e.Exception.ToString());
        if (e.Exception is OutOfMemoryException || MainWindow is not MainWindow { IsLoaded: true } window) return;
        // A failure in layout or rendering comes back on every pass; let a repeat end the process so recovery takes over.
        if (DateTime.UtcNow - _lastHandled < TimeSpan.FromSeconds(5)) return;
        _lastHandled = DateTime.UtcNow;
        window.ShowProblem(Problems.Crashed());
        e.Handled = true;
    }

    private DateTime _lastHandled;

    /// <summary>
    /// The files a command line asks for: each argument is a path, except one that starts with <c>lazypdf:</c>, which
    /// stands for the files in the address (<see cref="LazyPdfAddress"/>). The scheme's command is <c>"exe" "%1"</c>, so
    /// an address with a quote in it can add arguments of its own: when the first one is an address, it is the only
    /// one read.
    /// </summary>
    internal static IReadOnlyList<string> FilesOf(IEnumerable<string> args)
    {
        var all = args.Where(arg => arg.Length > 0).ToList();
        if (all.Count > 0 && LazyPdfAddress.IsAddress(all[0])) return [.. LazyPdfAddress.Parse(all[0])];
        return [.. all.SelectMany(arg => LazyPdfAddress.IsAddress(arg) ? LazyPdfAddress.Parse(arg) : FullPath(arg))];

        // An argument that is not a usable path is skipped: no window exists yet to say so.
        static string[] FullPath(string arg)
        {
            try { return [Path.GetFullPath(arg)]; }
            catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException) { return []; }
        }
    }

    /// <summary>Files handed over by a second start: opened at once, or kept for the window if it is not open yet.</summary>
    private void Opened(IReadOnlyList<string> paths) => Dispatcher.BeginInvoke(() =>
    {
        if (MainWindow is MainWindow { IsLoaded: true } window) window.OpenFiles(paths);
        else StartupFiles = [.. StartupFiles, .. paths];
    });

    protected override void OnExit(ExitEventArgs e)
    {
        Panels.Attachments.AttachmentsSidePanel.DeleteOpenedCopies();
        _channel?.Dispose();
        _instance?.ReleaseMutex();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
