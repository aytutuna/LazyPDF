using System.Windows;
using System.Windows.Automation;
using System.Runtime.InteropServices;
using System.Windows.Controls;
using System.Windows.Interop;

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
            ShowInTaskbar = false,
            Owner = Window.GetWindow(host),
            Title = _tab?.Title ?? "Lazy PDF",
            Content = this,
        };
        _screen.SourceInitialized += Screen_SourceInitialized;
        _screen.SetResourceReference(Window.BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
        _screen.SetResourceReference(Window.FontFamilyProperty, "TextFontFamily");
        AutomationProperties.SetName(_screen, Loc.T("Page viewer"));
        _screen.Closed += Screen_Closed;
        _screen.Show();
        Surface.Focus();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // Place a normal-sized window on the owner's monitor first, so the maximise lands there and un-maximising leaves a visible window.
    private void Screen_SourceInitialized(object? sender, EventArgs e)
    {
        var screen = (Window)sender!;
        var owner = screen.Owner is null ? IntPtr.Zero : new WindowInteropHelper(screen.Owner).Handle;
        var monitor = owner == IntPtr.Zero ? IntPtr.Zero : MonitorFromWindow(owner, MonitorDefaultToNearest);
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref info))
        {
            int w = (info.Monitor.Right - info.Monitor.Left) * 4 / 5, h = (info.Monitor.Bottom - info.Monitor.Top) * 4 / 5;
            int x = info.Monitor.Left + (info.Monitor.Right - info.Monitor.Left - w) / 2;
            int y = info.Monitor.Top + (info.Monitor.Bottom - info.Monitor.Top - h) / 2;
            SetWindowPos(new WindowInteropHelper(screen).Handle, IntPtr.Zero, x, y, w, h, SwpNoZOrder | SwpNoActivate);
        }
        screen.WindowState = WindowState.Maximized;
    }

    private const uint MonitorDefaultToNearest = 2;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public NativeRect Monitor, Work;
        public uint Flags;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);

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
