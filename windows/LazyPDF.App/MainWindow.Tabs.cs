// The tab strip: picking, closing (the button, or a click of the middle button) and dragging a tab to
// another place in the strip. Home stays first.

using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;

namespace LazyPDF.App;

public partial class MainWindow
{
    private const string TabFormat = "LazyPDF.Tab";

    private Point _dragStart;
    private DocumentTab? _dragTab;
    private TabStripPanel? _tabPanel;

    private void TabList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        _tabPanel?.InvalidateArrange();
        if (_refreshing) return;
        if (TabList.SelectedItem is ITab tab) _vm.ActiveTab = tab;
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
            item.Click += (_, _) => _vm.ActiveTab = picked;
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
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
        DragDrop.DoDragDrop(TabList, new DataObject(TabFormat, tab), DragDropEffects.Move);
    }

    private void TabList_DragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(TabFormat)) return;
        e.Effects = DragDropEffects.Move;
        e.Handled = true;
    }

    private void TabList_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(TabFormat) is not DocumentTab tab) return;
        var target = TabAt(e.OriginalSource);
        _vm.MoveTab(tab, target is null ? _vm.Strip.Count - 1 : _vm.Strip.IndexOf(target));
        e.Handled = true;
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
