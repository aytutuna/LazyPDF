// The tab strip: picking, closing (the button, or a click of the middle button) and dragging a tab to
// another place in the strip. Home stays first.

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;

namespace LazyPDF.App;

public partial class MainWindow
{
    // The data of a dragged tab is its id: a stale or foreign drop resolves to nothing instead of an object from elsewhere.
    internal const string TabIdFormat = "LazyPDF.TabId";

    // Farther than this from the strip, in device-independent pixels, a drag that nobody took opens a window.
    private const double TearOutDistance = 60;

    private Point _dragStart;
    private DocumentTab? _dragTab;
    private bool _closing;
    private bool _closeWhenIdle;
    private bool _waitingForBatch;
    private TabStripPanel? _tabPanel;
    private TabDropMarker? _dropMarker;

    private void TabList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        _tabPanel?.InvalidateArrange();
        if (_refreshing || TabList.SelectedItem is not ITab tab) return;
        if (!HandedInOnSwitch())
        {
            _refreshing = true;
            try { TabList.SelectedItem = _vm.ActiveTab; }
            finally { _refreshing = false; }
            return;
        }
        _vm.ActiveTab = tab;
    }

    // The panel is made by the list's template, so it is found once the list has been laid out.
    private void HookTabPanel()
    {
        if (_tabPanel is not null || FindDescendant<TabStripPanel>(TabList) is not { } panel) return;
        _tabPanel = panel;
        panel.OverflowChanged += (_, _) => Dispatcher.BeginInvoke(ShowTabOverflow);
        ShowTabOverflow();
    }

    private void ShowTabOverflow() => TabOverflow.Visibility = _tabPanel is { Overflows: true } ? Visibility.Visible : Visibility.Collapsed;

    private static T? FindDescendant<T>(DependencyObject node) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
        {
            var child = VisualTreeHelper.GetChild(node, i);
            if (child is T found) return found;
            if (FindDescendant<T>(child) is { } deeper) return deeper;
        }
        return null;
    }

    private void TabOverflow_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = TabOverflow, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        foreach (var tab in _vm.Strip)
        {
            var item = new MenuItem { Header = tab.Title, IsChecked = ReferenceEquals(tab, _vm.ActiveTab) };
            AutomationProperties.SetName(item, tab.AutomationName);
            var picked = tab;
            item.Click += (_, _) =>
            {
                if (HandedInOnSwitch()) _vm.ActiveTab = picked;
            };
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    [DllImport("user32.dll")]
    private static extern bool IsWindowEnabled(IntPtr hwnd);

    /// <summary>
    /// False while a tab cannot arrive here: a dialog of this window is up (a file dialog disables only its owner and
    /// sets nothing else; Combine would then add its files to whichever tab arrived), an action runs, an overlay shows
    /// or words typed in a tool are not settled. Words are handed in as they are on any tab switch.
    /// </summary>
    internal bool CanTakeTab()
    {
        var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        return (handle == IntPtr.Zero || IsWindowEnabled(handle)) && !Modal && !_actionRunning && HandedInOnSwitch();
    }

    // The checks that belong to the window the tab leaves; they run before a window is made for it.
    private bool CanLeave(DocumentTab tab)
    {
        if (_actionRunning)
        {
            _vm.ShowNotice(Loc.T("Tab not moved"), Loc.T("Wait for the job to end, or cancel it, then move the tab."));
            return false;
        }
        if (!HandInTyping(tab)) return false;
        if (_vm.CanRelease(tab, out var reason)) return true;
        _vm.ShowNotice(Loc.T("Tab not moved"), reason);
        return false;
    }

    /// <summary>Moves a tab to another window. False, with the reason shown here, when it stays.</summary>
    internal bool MoveTab(DocumentTab tab, MainWindow target, int index)
    {
        if (!CanLeave(tab) || !_vm.Registry.Transfer(tab, _vm, target._vm, index, target.CanTakeTab())) return false;
        target._vm.SetStatus(Loc.T("Moved {0} to another window.", tab.Title));
        target.OpenFiles([]);
        target.Dispatcher.BeginInvoke(target.FocusActiveTab, System.Windows.Threading.DispatcherPriority.Loaded);
        CloseWhenEmpty();
        // Keyboard focus here would pull the activation back from the window the tab went to.
        if (IsLoaded) Dispatcher.BeginInvoke(() =>
        {
            if (IsActive) FocusActiveTab();
        }, System.Windows.Threading.DispatcherPriority.Loaded);
        return true;
    }

    /// <summary>Moves a tab into a window of its own, at <paramref name="at"/> (device-independent pixels) or beside this one. False when it stays; then no window appears.</summary>
    internal bool TearOut(DocumentTab tab, Point? at = null)
    {
        if (!CanLeave(tab)) return false;
        var window = new MainWindow(_vm.Registry, _vm.Recovery, primary: false, at);
        if (!_vm.Registry.Transfer(tab, _vm, window._vm, 1))
        {
            window.Close();
            return false;
        }
        window.Show();
        window._vm.SetStatus(Loc.T("Moved {0} to a new window.", tab.Title));
        window.Dispatcher.BeginInvoke(window.FocusActiveTab, System.Windows.Threading.DispatcherPriority.Loaded);
        CloseWhenEmpty();
        return true;
    }

    // A window made for a tab goes when the tab leaves it, unless it still owns a batch window or a file is still
    // being opened in it; it waits for those and looks again.
    private void CloseWhenEmpty()
    {
        _closeWhenIdle = false;
        if (IsPrimary || _closing || _vm.Documents.Any()) return;
        if (_vm.IsOpening || _held.Count > 0)
        {
            _closeWhenIdle = true;
            return;
        }
        if (_waitingForBatch) return;
        _waitingForBatch = Tools.Batch.BatchWindow.WhenClosed(_vm, () =>
        {
            _waitingForBatch = false;
            CloseWhenEmpty();
        });
        if (!_waitingForBatch) Close();
    }

    private void FocusActiveTab() =>
        (TabList.ItemContainerGenerator.ContainerFromItem(_vm.ActiveTab) as ListBoxItem)?.Focus();

    private void TabList_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (TabAt(e.OriginalSource) is not DocumentTab tab)
        {
            e.Handled = true;
            return;
        }
        TabList.ContextMenu = TabMenu(tab);
    }

    internal ContextMenu TabMenu(DocumentTab tab)
    {
        int index = _vm.Strip.IndexOf(tab);
        var others = _vm.Documents.Where(d => !ReferenceEquals(d, tab)).ToList();
        var right = _vm.Strip.Skip(index + 1).OfType<DocumentTab>().ToList();
        var menu = new ContextMenu();
        AddItem(menu, Loc.T("Move to new window"), !_vm.IsBusy, () => TearOut(tab));
        var windows = WindowHub.Windows.Where(w => !ReferenceEquals(w, this)).ToList();
        if (windows.Count > 0)
        {
            var submenu = new MenuItem { Header = Loc.T("Move to window") };
            AutomationProperties.SetName(submenu, submenu.Header.ToString());
            foreach (var window in windows)
            {
                var target = window;
                string name = Loc.T("Window {0}: {1}", WindowHub.Windows.ToList().IndexOf(target) + 1, target.Title);
                var entry = new MenuItem { Header = name.Replace("_", "__") };
                AutomationProperties.SetName(entry, name);
                if (target._vm.ActiveDocument?.Path is { } path) AutomationProperties.SetHelpText(entry, path);
                entry.Click += (_, _) => MoveTab(tab, target, int.MaxValue);
                submenu.Items.Add(entry);
            }
            menu.Items.Add(submenu);
        }
        menu.Items.Add(new Separator());
        AddItem(menu, Loc.T("Close"), !_vm.IsBusy, () => RequestClose(tab));
        AddItem(menu, Loc.T("Close other tabs"), !_vm.IsBusy && others.Count > 0, () => RequestCloseMany(others));
        AddItem(menu, Loc.T("Close tabs to the right"), !_vm.IsBusy && right.Count > 0, () => RequestCloseMany(right));
        menu.Items.Add(new Separator());
        AddItem(menu, Loc.T("Copy path"), tab.Path is not null, () => CopyPath(tab.Path!));
        AddItem(menu, Loc.T("Show in folder"), tab.Path is not null, () => ShowInFolder(tab.Path!));
        menu.Items.Add(new Separator());
        AddItem(menu, Loc.T("Reopen closed tab"), _vm.ClosedFiles.Count > 0, () => _ = _vm.ReopenClosedAsync());
        return menu;
    }

    private static void AddItem(ContextMenu menu, string header, bool enabled, Action run)
    {
        var item = new MenuItem { Header = header, IsEnabled = enabled };
        AutomationProperties.SetName(item, header);
        item.Click += (_, _) => run();
        menu.Items.Add(item);
    }

    private static void CopyPath(string path)
    {
        try
        {
            Clipboard.SetText(path);
        }
        catch (COMException)
        {
        }
    }

    private void ShowInFolder(string path)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\""));
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            _vm.ShowProblem(new Problem(Loc.T("Not opened"), Loc.T("Windows could not open {0}.", path)));
        }
    }

    private void CloseTab_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is DocumentTab tab) RequestClose(tab);
        e.Handled = true;
    }

    private void TabList_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Middle || TabAt(e.OriginalSource) is not DocumentTab tab) return;
        RequestClose(tab);
        e.Handled = true;
    }

    private void TabList_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Delete || TabAt(e.OriginalSource) is not DocumentTab tab) return;
        RequestClose(tab);
        e.Handled = true;
    }

    private void TabList_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _dragStart = e.GetPosition(null);
        _dragTab = e.OriginalSource is DependencyObject source && FindAncestor<Button>(source) is null ? TabAt(e.OriginalSource) as DocumentTab : null;
    }

    private void TabList_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _dragTab is not { } tab) return;
        var now = e.GetPosition(null);
        if (Math.Abs(now.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(now.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _dragTab = null;
        StartTabDrag(tab);
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT point);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X, Y;
    }

    /// <summary>What a finished drag leaves to do.</summary>
    public enum DragOutcome { Nothing, MoveToWindow, TearOut }

    /// <summary>
    /// A drop on a strip of this window reordered it already, and a drop on another window's strip was only noted, to
    /// be carried out here once the drag loop is over. A drag nobody took opens a window when it ends far from the
    /// strip, wherever that is: a maximized window covers its whole screen, so 'outside every window' would never hold.
    /// </summary>
    internal static DragOutcome OutcomeOf(DragDropEffects result, bool escaped, bool droppedElsewhere, Point cursor, Rect strip, double distance)
    {
        if (droppedElsewhere) return DragOutcome.MoveToWindow;
        if (result != DragDropEffects.None || escaped) return DragOutcome.Nothing;
        bool away = cursor.X < strip.Left - distance || cursor.X > strip.Right + distance
            || cursor.Y < strip.Top - distance || cursor.Y > strip.Bottom + distance;
        return away ? DragOutcome.TearOut : DragOutcome.Nothing;
    }

    // The drag starts as a plain reorder. What leaves the window is decided, and checked, after the drag loop ends.
    private void StartTabDrag(DocumentTab tab)
    {
        bool escaped = false;
        POINT last = default;
        void Watch(object sender, QueryContinueDragEventArgs e)
        {
            escaped |= e.EscapePressed;
            GetCursorPos(out last);
        }
        WindowHub.Dropped = null;
        TabList.QueryContinueDrag += Watch;
        DragDropEffects result;
        try
        {
            result = DragDrop.DoDragDrop(TabList, new DataObject(TabIdFormat, tab.Id.ToString()), DragDropEffects.Move);
        }
        finally
        {
            TabList.QueryContinueDrag -= Watch;
        }
        var dropped = WindowHub.Dropped;
        WindowHub.Dropped = null;
        if (!_vm.Strip.Contains(tab)) return;
        var cursor = new Point(last.X, last.Y);
        var origin = TabList.PointToScreen(new Point(0, 0));
        var scale = VisualTreeHelper.GetDpi(this);
        var strip = new Rect(origin.X, origin.Y, TabList.ActualWidth * scale.DpiScaleX, TabList.ActualHeight * scale.DpiScaleY);
        switch (OutcomeOf(result, escaped, dropped is { } && !ReferenceEquals(dropped.Value.Window, this), cursor, strip, TearOutDistance * scale.DpiScaleX))
        {
            case DragOutcome.MoveToWindow:
                MoveTab(tab, dropped!.Value.Window, dropped.Value.Index);
                break;
            case DragOutcome.TearOut:
                // The new window's corner goes where the tab was let go, so the tab is under the cursor.
                TearOut(tab, new Point(cursor.X / scale.DpiScaleX - 80, cursor.Y / scale.DpiScaleY - 20));
                break;
        }
    }

    private void TabList_DragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(TabIdFormat)) return;
        var tab = DraggedTab(e.Data);
        e.Effects = tab is null ? DragDropEffects.None : DragDropEffects.Move;
        e.Handled = true;
        // A tab of this window only changes places, which the strip shows as it happens; one from another window needs to be shown where it lands.
        if (tab is null || _vm.Strip.Contains(tab)) HideDropMarker();
        else ShowDropMarker(ReferenceEquals(sender, TabOverflow) ? null : TabAt(e.OriginalSource));
    }

    private void TabList_DragLeave(object sender, DragEventArgs e) => HideDropMarker();

    private void ShowDropMarker(ITab? before)
    {
        // Home stays first, so a tab dropped on it lands after it.
        int index = before is null ? _vm.Strip.Count : Math.Max(1, _vm.Strip.IndexOf(before));
        double x = 0;
        if (index >= _vm.Strip.Count)
        {
            if (TabList.ItemContainerGenerator.ContainerFromIndex(_vm.Strip.Count - 1) is FrameworkElement last)
                x = last.TransformToAncestor(TabList).Transform(new Point(last.ActualWidth, 0)).X;
        }
        else if (TabList.ItemContainerGenerator.ContainerFromIndex(index) is FrameworkElement at)
        {
            x = at.TransformToAncestor(TabList).Transform(new Point(0, 0)).X;
        }
        if (_dropMarker is null)
        {
            if (System.Windows.Documents.AdornerLayer.GetAdornerLayer(TabList) is not { } layer) return;
            layer.Add(_dropMarker = new TabDropMarker(TabList));
        }
        _dropMarker.MoveTo(x);
    }

    private void HideDropMarker()
    {
        if (_dropMarker is null) return;
        System.Windows.Documents.AdornerLayer.GetAdornerLayer(TabList)?.Remove(_dropMarker);
        _dropMarker = null;
    }

    private void TabList_Drop(object sender, DragEventArgs e)
    {
        HideDropMarker();
        if (!e.Data.GetDataPresent(TabIdFormat)) return;
        e.Effects = DropTab(DraggedTab(e.Data), TabAt(e.OriginalSource));
        e.Handled = true;
    }

    private void TabOverflow_Drop(object sender, DragEventArgs e)
    {
        HideDropMarker();
        if (!e.Data.GetDataPresent(TabIdFormat)) return;
        e.Effects = DropTab(DraggedTab(e.Data), null);
        e.Handled = true;
    }

    // The tab with the dragged id, in whichever window holds it now; null for an id nobody owns.
    internal DocumentTab? DraggedTab(IDataObject data) =>
        data.GetData(TabIdFormat) is string text && Guid.TryParse(text, out var id) ? _vm.Registry.Find(id)?.Documents.FirstOrDefault(d => d.Id == id) : null;

    /// <summary>
    /// A drop on this window's strip, on <paramref name="onTab"/> or on empty space. Inside the source's drag loop
    /// nothing is checked or asked: a tab of this window is reordered, one from another is only noted for its own
    /// window to move once the loop is over.
    /// </summary>
    internal DragDropEffects DropTab(DocumentTab? tab, ITab? onTab)
    {
        if (tab is null) return DragDropEffects.None;
        if (_vm.Strip.Contains(tab))
        {
            _vm.MoveTab(tab, onTab is null ? _vm.Strip.Count - 1 : _vm.Strip.IndexOf(onTab));
            return DragDropEffects.Move;
        }
        // Over empty space, or the overflow button, the tab goes last.
        WindowHub.Dropped = (this, onTab is null ? _vm.Strip.Count : _vm.Strip.IndexOf(onTab));
        return DragDropEffects.Move;
    }

    private ITab? TabAt(object source) =>
        source is DependencyObject element && ItemsControl.ContainerFromElement(TabList, element) is ListBoxItem { DataContext: ITab tab } ? tab : null;

    private static T? FindAncestor<T>(DependencyObject node) where T : DependencyObject
    {
        for (var current = node; current is not null; current = current is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(current) : LogicalTreeHelper.GetParent(current))
        {
            if (current is T found) return found;
        }
        return null;
    }
}
