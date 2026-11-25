using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tests;

/// <summary>
/// A viewer for the fill layer in a shown, off-screen window, so its controls can take the keyboard. The overlays are
/// stacked down a canvas, or live in a real <see cref="PageSurface"/> where the order of overlays matters.
/// </summary>
internal class FormStand : DispatchProxy, IDisposable
{
    private DocumentTab _tab = null!;
    private Canvas? _root;
    private PageSurface? _surface;

    public Window Window { get; private set; } = null!;

    public int Rotation { get; set; }

    public List<(int Page, Rect Area)> Reveals { get; } = [];

    public static IDocumentViewer Create(DocumentTab tab, out FormStand stand, bool surface = false)
    {
        var viewer = Create<IDocumentViewer, FormStand>();
        stand = (FormStand)(object)viewer;
        stand._tab = tab;
        UIElement content;
        if (surface)
        {
            stand._surface = new PageSurface();
            stand._surface.Show(tab);
            content = stand._surface;
        }
        else content = stand._root = new Canvas();
        stand.Window = new Window
        {
            Content = content,
            Width = 800,
            Height = 1000,
            ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = -20000,
            Top = 0,
        };
        stand.Window.Show();
        return viewer;
    }

    public void Dispose() => Window.Close();

    private PageOverlay Overlay(int page)
    {
        if (_surface is not null) return _surface.Overlay(page);
        foreach (var child in _root!.Children.OfType<PageOverlay>())
        {
            if (child.Page == page) return child;
        }
        var overlay = new PageOverlay(page, PageSize(page));
        Canvas.SetTop(overlay, page * 900);
        _root.Children.Add(overlay);
        return overlay;
    }

    private Size PageSize(int page)
    {
        var g = new PageGeometry(_tab.Document.Pages[page]);
        return new Size(g.Width, g.Height);
    }

    protected override object? Invoke(MethodInfo? method, object?[]? args)
    {
        switch (method!.Name)
        {
            case "Overlay": return Overlay((int)args![0]!);
            case "PageSize": return PageSize((int)args![0]!);
            case "Geometry": return new PageGeometry(_tab.Document.Pages[(int)args![0]!]);
            case "get_Rotation": return Rotation;
            case "get_PageCount": return _tab.Document.Pages.Count;
            case "get_VisiblePages": return Enumerable.Range(0, _tab.Document.Pages.Count).ToArray();
            case "Reveal":
                Reveals.Add(((int)args![0]!, (Rect)args[1]!));
                return null;
            default:
                return method.ReturnType == typeof(void) || !method.ReturnType.IsValueType ? null : Activator.CreateInstance(method.ReturnType);
        }
    }
}
