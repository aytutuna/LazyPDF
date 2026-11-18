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
    public static void BeginExit(DocumentRegistry registry)
    {
        if (Exiting) return;
        Exiting = true;
        var (files, active) = registry.Session();
        AppPreferencesStore.Update(p =>
        {
            p.LastFiles = p.ReopenLast ? files : [];
            p.LastActive = p.ReopenLast ? active : null;
        });
    }

    /// <summary>A window did not close after all.</summary>
    public static void EndExit() => Exiting = false;
}
