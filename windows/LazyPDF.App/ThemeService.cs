// From Lazy Print's ThemeService.cs.
// Application.ThemeMode is marked [Experimental("WPF0001")] in .NET 10, but it is the supported
// switch for the built-in Fluent theme. The suppression is limited to this file.
#pragma warning disable WPF0001
using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Services;

namespace LazyPDF.App;

/// <summary>
/// Applies the Fluent theme variant (follow Windows, light or dark) and keeps the decorative
/// shadows off where they do not belong. The Fluent dictionary merged first in App.xaml follows
/// the system light/dark setting on its own; this class only handles the user's override.
/// </summary>
public static class ThemeService
{
    /// <summary>Resource keys of the elevation shadows in Styles/Tokens.xaml.</summary>
    private static readonly string[] ShadowKeys = ["CardHoverShadow", "PageShadow", "DialogShadow"];

    private static readonly Dictionary<string, object> Shadows = [];
    private static bool _initialized;

    public static AppAppearance Appearance { get; private set; } = AppAppearance.System;

    /// <summary>Load the saved preference, apply it, and re-apply when high contrast is toggled.</summary>
    public static void Initialize()
    {
        if (_initialized) return;
        _initialized = true;
        SystemParameters.StaticPropertyChanged += SystemParameters_StaticPropertyChanged;
        Apply(AppPreferencesStore.Load().Appearance);
    }

    /// <summary>Apply without saving.</summary>
    public static void Apply(AppAppearance appearance)
    {
        Appearance = appearance;
        if (Application.Current is not { } app) return;

        // A contrast theme always wins over a light/dark override: the Fluent dictionary that
        // follows the system switches to its high-contrast variant on its own.
        app.ThemeMode = SystemParameters.HighContrast
            ? ThemeMode.System
            : appearance switch
            {
                AppAppearance.Light => ThemeMode.Light,
                AppAppearance.Dark => ThemeMode.Dark,
                _ => ThemeMode.System,
            };
        UpdateShadows(app);
        app.Dispatcher.BeginInvoke(DispatcherPriority.ContextIdle, () => RemeasureAll(app));
    }

    /// <summary>
    /// A theme switch re-applies every style and template. If layout runs while that is still
    /// settling (a resize or a content change at the same moment), an element can end up
    /// re-measured during the arrange pass, which WPF does not report to its parent: the parent
    /// keeps the old size and clips the element (seen as a cut-off button label). Re-measuring
    /// every element once the switch has settled clears any such stale size.
    /// </summary>
    private static void RemeasureAll(Application app)
    {
        foreach (Window window in app.Windows) Invalidate(window);

        static void Invalidate(DependencyObject node)
        {
            if (node is UIElement element) element.InvalidateMeasure();
            int count = VisualTreeHelper.GetChildrenCount(node);
            for (int i = 0; i < count; i++) Invalidate(VisualTreeHelper.GetChild(node, i));
        }
    }

    /// <summary>Apply and persist (the Appearance menu).</summary>
    public static void Set(AppAppearance appearance)
    {
        Apply(appearance);
        AppPreferencesStore.Update(preferences => preferences.Appearance = appearance);
    }

    /// <summary>
    /// Shadows are dropped in high contrast (pure decoration there) and under software rendering
    /// (e.g. remote desktop), where blur effects are slow. Styles reference them dynamically.
    /// </summary>
    private static void UpdateShadows(Application app)
    {
        bool off = SystemParameters.HighContrast || (RenderCapability.Tier >> 16) < 2;
        foreach (string key in ShadowKeys)
        {
            if (!Shadows.ContainsKey(key) && app.TryFindResource(key) is { } effect)
            {
                Shadows[key] = effect;
            }
            if (Shadows.TryGetValue(key, out var shadow))
            {
                app.Resources[key] = off ? null : shadow;
            }
        }
    }

    private static void SystemParameters_StaticPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SystemParameters.HighContrast))
        {
            Application.Current?.Dispatcher.BeginInvoke(() => Apply(Appearance));
        }
    }
}
