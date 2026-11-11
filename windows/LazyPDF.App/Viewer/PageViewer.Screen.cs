using System.Windows;
using System.Windows.Automation;
using System.Runtime.InteropServices;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

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

    // ----- Presenting: one page at a time on black, over the full screen window.

    private readonly DispatcherTimer _hidePointer = new() { Interval = TimeSpan.FromSeconds(3) };
    private (int Columns, bool Cover, bool Continuous, FitMode Fit, double Zoom) _beforePresent;
    private bool _presenting;
    private bool _presentOwnsScreen;
    private bool _presentDown;
    private int _wheel;

    private const uint EsContinuous = 0x80000000;
    private const uint EsDisplayRequired = 0x00000002;

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint flags);

    public bool Presenting
    {
        get => _presenting;
        set
        {
            if (value == _presenting) return;
            if (value) BeginPresent();
            else
            {
                bool close = _presentOwnsScreen;
                EndPresent();
                if (close) _screen?.Close();
            }
        }
    }

    private void BeginPresent()
    {
        if (_tab is null) return;
        ReadingMode = false;
        _presentOwnsScreen = !FullScreen;
        if (_presentOwnsScreen) Enter();
        _presenting = true;
        _beforePresent = (Surface.Columns, Surface.Cover, Surface.Continuous, Surface.Fit, Surface.Zoom);
        Surface.SetArrangement(1, false, false);
        Surface.SetFit(FitMode.Page);
        Bar.Visibility = Visibility.Collapsed;
        HideFind();
        Scroller.HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden;
        Scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Hidden;
        if (_screen is not null) _screen.Background = Brushes.Black;
        ShowToast(Loc.T("Click or press Right to go on. Esc to leave."));
        SetThreadExecutionState(EsContinuous | EsDisplayRequired);
        _hidePointer.Start();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void EndPresent()
    {
        if (!_presenting) return;
        _presenting = false;
        _presentOwnsScreen = false;
        _presentDown = false;
        _hidePointer.Stop();
        Surface.SetArrangement(_beforePresent.Columns, _beforePresent.Cover, _beforePresent.Continuous);
        if (_beforePresent.Fit == FitMode.None) Surface.SetZoom(_beforePresent.Zoom);
        else Surface.SetFit(_beforePresent.Fit);
        Bar.Visibility = Visibility.Visible;
        Scroller.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        Scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        if (_screen is not null)
        {
            _screen.SetResourceReference(Window.BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
            _screen.ForceCursor = false;
            _screen.Cursor = null;
        }
        SetThreadExecutionState(EsContinuous);
        HideToast();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void ShowPointer()
    {
        if (!_presenting) return;
        if (_screen is not null)
        {
            _screen.ForceCursor = false;
            _screen.Cursor = null;
        }
        _hidePointer.Stop();
        _hidePointer.Start();
    }

    private void HidePointer()
    {
        if (LinkCard.Visibility == Visibility.Visible || _screen is null) return;
        _screen.ForceCursor = true;
        _screen.Cursor = Cursors.None;
        _hidePointer.Stop();
    }

    // The keys that turn pages; false for any other, and for all of them while a link card has the keyboard.
    internal bool PresentWithKeys(Key key, bool shift)
    {
        if (!_presenting || LinkCard.Visibility == Visibility.Visible) return false;
        switch (key)
        {
            case Key.Right or Key.Down or Key.PageDown or Key.N:
            case Key.Space when !shift:
                StepPage(1);
                break;
            case Key.Left or Key.Up or Key.PageUp or Key.Back or Key.P:
            case Key.Space when shift:
                StepPage(-1);
                break;
            case Key.Home:
                GoToPage(0);
                break;
            case Key.End:
                GoToPage(Surface.PageCount - 1);
                break;
            case Key.Escape:
                Presenting = false;
                break;
            case Key.F11:
                Presenting = false;
                FullScreen = false;
                break;
            default:
                return false;
        }
        return true;
    }

    private void Screen_Closed(object? sender, EventArgs e)
    {
        EndPresent();
        var screen = _screen!;
        _screen = null;
        screen.Content = null;
        _screenHost!.Content = this;
        _screenHost = null;
        Surface.Focus();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }
}
