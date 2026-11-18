namespace LazyPDF.App.Services;

/// <summary>The open main windows and the one used last; the only place that knows the window type.</summary>
internal static class WindowHub
{
    private static readonly List<MainWindow> _windows = [];

    public static IReadOnlyList<MainWindow> Windows => _windows;

    /// <summary>The window loaded or used last, for events that belong to no window: a second start, a crash notice.</summary>
    public static MainWindow? Active { get; set; }

    /// <summary>Where an event with no window of its own goes: the active window, or any that is loaded.</summary>
    public static MainWindow? Target => Active is { IsLoaded: true } active ? active : _windows.FirstOrDefault(w => w.IsLoaded);

    /// <summary>True while the whole app is ending, so the windows closing one after another keep nothing of their own.</summary>
    public static bool Exiting { get; private set; }

    // What windows closed on purpose in this pass of the message loop held; 'Close all windows' closes them one after another in it.
    private static List<string>? _closedFiles;
    private static string? _closedActive;
    private static int _pass;

    // WPF closes every window after SessionEnding whatever a window answers, so that exit is never called off.
    private static bool _sessionEnding;

    public static void Register(MainWindow window) => _windows.Add(window);

    public static void Unregister(MainWindow window)
    {
        _windows.Remove(window);
        if (ReferenceEquals(Active, window)) Active = _windows.LastOrDefault();
        // The application's main window is what a dialog without an owner and the shutdown rules look at.
        if (System.Windows.Application.Current is { } app && (app.MainWindow is null || ReferenceEquals(app.MainWindow, window))) app.MainWindow = Active;
    }

    /// <summary>The window that takes over what a closing one leaves: the first window, else the one used last.</summary>
    public static MainWindow? Survivor(MainWindow closing) =>
        _windows.FirstOrDefault(w => w.IsPrimary && !ReferenceEquals(w, closing))
        ?? (ReferenceEquals(Active, closing) ? null : Active)
        ?? _windows.FirstOrDefault(w => !ReferenceEquals(w, closing));

    /// <summary>
    /// The app is ending with every window: what the next start reopens is the union of all of them, written now, once,
    /// since the first window to close would otherwise hand its files to the next and only the last would be kept.
    /// </summary>
    public static void BeginExit(DocumentRegistry registry, bool session = false)
    {
        _sessionEnding |= session;
        if (Exiting) return;
        Exiting = true;
        var (files, active) = registry.Session();
        if (_closedFiles is not null)
        {
            files = [.. _closedFiles.Concat(files).Distinct(StringComparer.OrdinalIgnoreCase)];
            active = _closedActive ?? active;
        }
        AppPreferencesStore.Update(p =>
        {
            p.LastFiles = p.ReopenLast ? files : [];
            p.LastActive = p.ReopenLast ? active : null;
        });
    }

    /// <summary>True when another window closed on purpose a moment ago, in the same pass of the message loop: the windows are closing together.</summary>
    public static bool ClosedTogether => _closedFiles is not null;

    /// <summary>A window is closing on its own and leaves <paramref name="files"/>; a window closing right after it is part of a close of all.</summary>
    public static void NoteClosed(IEnumerable<string> files, string? active)
    {
        if (_closedFiles is null)
        {
            _closedFiles = [];
            _closedActive = active;
            int pass = ++_pass;
            System.Windows.Threading.Dispatcher.CurrentDispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
            {
                if (pass == _pass) EndPass();
            });
        }
        _closedFiles.AddRange(files);
    }

    /// <summary>The queued closes have all run. Windows still open then were not part of an exit, so what was written for one is theirs to rewrite.</summary>
    internal static void EndPass()
    {
        _pass++;
        _closedFiles = null;
        _closedActive = null;
        if (_windows.Count > 0 && !_sessionEnding) Exiting = false;
    }

    /// <summary>A window did not close after all. An exit that came with the end of the Windows session carries on.</summary>
    public static void EndExit()
    {
        if (!_sessionEnding) Exiting = false;
    }

    /// <summary>Forgets the windows' shared state, for tests that build windows of their own.</summary>
    internal static void Reset()
    {
        Exiting = _sessionEnding = false;
        _closedFiles = null;
        _closedActive = null;
        _pass++;
        Active = null;
    }
}
