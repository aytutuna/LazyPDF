namespace LazyPDF.App.Services;

/// <summary>The open main windows and the one used last; the only place that knows the window type.</summary>
internal static class WindowHub
{
    private static readonly List<MainWindow> _windows = [];

    public static IReadOnlyList<MainWindow> Windows => _windows;

    /// <summary>The window loaded or used last, for events that belong to no window: a second start, a crash notice.</summary>
    public static MainWindow? Active { get; set; }

    public static void Register(MainWindow window) => _windows.Add(window);

    public static void Unregister(MainWindow window)
    {
        _windows.Remove(window);
        if (ReferenceEquals(Active, window)) Active = _windows.LastOrDefault();
    }
}
