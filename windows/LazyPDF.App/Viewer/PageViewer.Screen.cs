using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace LazyPDF.App.Viewer;

// Full screen: the viewer moves into a borderless window of its own and goes back when that closes.
public partial class PageViewer
{
    private Window? _screen;
    private ContentControl? _screenHost;

    public bool FullScreen
    {
        get => _screen is not null;
        set
        {
            if (value == FullScreen) return;
            if (value) Enter();
            else _screen!.Close();
        }
    }

    private void Enter()
    {
        if (LogicalTreeHelper.GetParent(this) is not ContentControl host) return;
        _screenHost = host;
        host.Content = null;
        _screen = new Window
        {
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            WindowState = WindowState.Maximized,
            ShowInTaskbar = false,
            Owner = Window.GetWindow(host),
            Title = _tab?.Title ?? "Lazy PDF",
            Content = this,
        };
        _screen.SetResourceReference(Window.BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
        _screen.SetResourceReference(Window.FontFamilyProperty, "TextFontFamily");
        AutomationProperties.SetName(_screen, Loc.T("Page viewer"));
        _screen.Closed += Screen_Closed;
        _screen.Show();
        Surface.Focus();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Screen_Closed(object? sender, EventArgs e)
    {
        var screen = _screen!;
        _screen = null;
        screen.Content = null;
        _screenHost!.Content = this;
        _screenHost = null;
        Surface.Focus();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }
}
