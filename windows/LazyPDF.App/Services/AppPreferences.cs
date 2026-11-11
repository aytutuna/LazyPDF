// From Lazy Print's AppPreferences.cs.
namespace LazyPDF.App.Services;

/// <summary>Light, dark, or whatever Windows is set to. The first case is the default (Global rule 8).</summary>
public enum AppAppearance
{
    System,
    Light,
    Dark,
}

/// <summary>What the Windows app remembers about its own window.</summary>
public sealed class AppPreferences
{
    public const double DefaultSidePanelWidth = 260;
    public const double DefaultInspectorWidth = 280;

    public AppAppearance Appearance { get; set; } = AppAppearance.System;

    /// <summary>"" follows Windows; "en" or "tr" forces that language from the next start.</summary>
    public string Language { get; set; } = "";

    /// <summary>The side panel left open (an id of <see cref="Tools.ToolCatalog.SidePanels"/>); empty when the rail is collapsed.</summary>
    public string SidePanel { get; set; } = "pages";

    /// <summary>The width of the side panel, in device-independent pixels.</summary>
    public double SidePanelWidth { get; set; } = DefaultSidePanelWidth;

    /// <summary>The width of the inspector, in device-independent pixels.</summary>
    public double InspectorWidth { get; set; } = DefaultInspectorWidth;

    /// <summary>Which inspector sections the user left open or closed: a tool's own key, open. No entry is the default.</summary>
    public Dictionary<string, bool> InspectorSections { get; set; } = [];

    /// <summary>The page tint picked in the viewer.</summary>
    public Viewer.PageTint Tint { get; set; } = Viewer.PageTint.None;

    /// <summary>Pages side by side in the viewer, 1 or 2.</summary>
    public int Columns { get; set; } = 1;

    /// <summary>Whether the first page stands alone when two columns are shown.</summary>
    public bool Cover { get; set; }

    /// <summary>Whether pages run on in one scroll rather than one at a time.</summary>
    public bool Continuous { get; set; } = true;

    /// <summary>Web sites whose links open without asking: "https://" and the lower-case host, at most 100, oldest first.</summary>
    public List<string> AllowedLinkHosts { get; set; } = [];

    /// <summary>The width of a page picture in the Pages panel, 72 to 192.</summary>
    public double ThumbnailWidth { get; set; } = 132;

    /// <summary>Whether the files open at close come back at the next start without a file.</summary>
    public bool ReopenLast { get; set; }

    /// <summary>The paths open when the window closed, in strip order; kept only while <see cref="ReopenLast"/> is on.</summary>
    public List<string> LastFiles { get; set; } = [];

    /// <summary>The path of the tab that was active at close.</summary>
    public string? LastActive { get; set; }

    /// <summary>Where the main window was left; null until it has been closed once.</summary>
    public WindowPlacement? Window { get; set; }
}

/// <summary>The main window's normal bounds in device-independent pixels, and whether it was maximised.</summary>
public sealed class WindowPlacement
{
    public double Left { get; set; }
    public double Top { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }
    public bool Maximized { get; set; }
}

/// <summary>preferences.json in %APPDATA%\Lazy PDF, read and written by the rules of Lazy Scan's settings files.</summary>
public static class AppPreferencesStore
{
    private static string Path(string directory) => System.IO.Path.Combine(directory, "preferences.json");

    public static AppPreferences Load() => Load(StoreFiles.DefaultDirectory);

    /// <summary>Re-reads the file, applies <paramref name="change"/> and saves, so each part of the app changes only its own preference.</summary>
    public static void Update(Action<AppPreferences> change) => Update(change, StoreFiles.DefaultDirectory);

    internal static AppPreferences Load(string directory)
    {
        var preferences = StoreFiles.Load<AppPreferences>(Path(directory)) ?? new AppPreferences();
        preferences.ThumbnailWidth = Math.Clamp(preferences.ThumbnailWidth, 72, 192);
        return preferences;
    }

    internal static void Update(Action<AppPreferences> change, string directory)
    {
        var preferences = Load(directory);
        change(preferences);
        StoreFiles.Write(preferences, Path(directory));
    }
}
