// The tool strip, the icon rail with its side panels, and the inspector. The panels come from
// Tools/ToolCatalog.cs; a panel is made once, the first time it is shown, and is attached to the document
// in view for as long as it is on screen.

using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools;

namespace LazyPDF.App;

public partial class MainWindow
{
    // Below this width the groups of the tool strip show their glyphs only.
    private const double CompactWidth = 1100;

    // Below this width the side panel and the inspector do not both fit beside the stage: the side panel gives way
    // while a tool is open, and the inspector shows only for a tool.
    private const double NarrowWidth = 900;

    private bool _narrow;
    private bool _actionRunning;
    private readonly List<string> _held = new();
    private InfoMessage? _heldMessage;
    private InfoMessage? _settledMessage;

    private readonly Dictionary<ToolGroup, Button> _groupButtons = [];
    private readonly Dictionary<string, ToggleButton> _railButtons = [];
    private readonly Dictionary<string, ToolPanel> _panels = [];
    private ToolPanel? _inspectorPanel;
    private DocumentTab? _inspectorTab;
    private ToolPanel? _sidePanel;
    private DocumentTab? _sideTab;

    // False while typed text waits for an answer; the side panel may hold some as well as the inspector.
    private bool HandedIn() => _inspectorPanel?.HandIn() != false && _sidePanel?.HandIn() != false;

    private void BuildToolStrip()
    {
        foreach (var group in Enum.GetValues<ToolGroup>())
        {
            string title = ToolCatalog.GroupTitle(group);
            var button = new Button
            {
                Style = (Style)FindResource("SubtleButtonStyle"),
                Content = title,
                ToolTip = title,
                Padding = new Thickness(10, 4, 10, 5),
            };
            LazyPDF.App.Icon.SetGlyph(button, ToolCatalog.GroupGlyph(group));
            AutomationProperties.SetName(button, title);
            button.Click += (_, _) => ShowGroupMenu(button, group);
            _groupButtons[group] = button;
            GroupPanel.Children.Add(button);
        }
    }

    private void ShowGroupMenu(Button button, ToolGroup group)
    {
        var menu = new ContextMenu { PlacementTarget = button, Placement = PlacementMode.Bottom };
        foreach (var tool in ToolCatalog.Tools.Where(t => t.Group == group))
        {
            var item = new MenuItem
            {
                Header = tool.Title,
                Icon = new TextBlock { Text = tool.Glyph, FontFamily = (FontFamily)FindResource("IconFontFamily") },
                IsChecked = tool.Id == _vm.ActiveToolId,
                ToolTip = tool.Summary,
            };
            AutomationProperties.SetName(item, tool.Title);
            string id = tool.Id;
            item.Click += (_, _) => _vm.SelectTool(id);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    private void UpdateToolStripMode(double width)
    {
        bool compact = width < CompactWidth;
        foreach (var button in _groupButtons.Values)
        {
            if (compact) button.ContentTemplate = (DataTemplate)FindResource("IconOnlyTemplate");
            else button.ClearValue(ContentControl.ContentTemplateProperty);
        }
    }

    private void RefreshToolStrip()
    {
        var active = _vm.ActiveTool?.Group;
        foreach (var (group, button) in _groupButtons)
        {
            bool on = group == active;
            // The outline shows the state where the label is hidden and where the fill matches the window.
            if (on)
            {
                button.SetResourceReference(Control.BackgroundProperty, "SubtleFillColorSecondaryBrush");
                button.SetResourceReference(Control.BorderBrushProperty, "AccentFillColorDefaultBrush");
            }
            else
            {
                button.Background = Brushes.Transparent;
                button.BorderBrush = Brushes.Transparent;
            }
            button.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
        }
    }

    private void BuildRail()
    {
        foreach (var side in ToolCatalog.SidePanels)
        {
            var button = new ToggleButton
            {
                Style = (Style)FindResource("RailButtonStyle"),
                Content = side.Glyph,
                ToolTip = side.Title,
            };
            AutomationProperties.SetName(button, side.Title);
            string id = side.Id;
            button.Click += (_, _) => ShowSidePanel(id);
            _railButtons[side.Id] = button;
            Rail.Children.Add(button);
        }
    }

    private void ContentArea_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        SettingsScroll.MaxHeight = Math.Max(0, e.NewSize.Height - 48);
        LimitPaneWidths();
        if (_narrow == e.NewSize.Width < NarrowWidth) return;
        _narrow = !_narrow;
        RefreshFromViewModel();
    }

    // The stage keeps 320 pixels; a window too narrow for the saved widths only clamps them. The inspector is
    // clamped first and the side panel takes what is left, so the result does not depend on the last layout.
    private void LimitPaneWidths()
    {
        var (side, inspector) = PaneLimits(ContentArea.ActualWidth - 48 - 320, _vm.SidePanelWidth, _vm.InspectorWidth,
            SidePane.Visibility == Visibility.Visible, Inspector.Visibility == Visibility.Visible);
        SideColumn.MaxWidth = side;
        InspectorColumn.MaxWidth = inspector;
    }

    internal static (double Side, double Inspector) PaneLimits(double room, double side, double inspector, bool sideShown, bool inspectorShown)
    {
        double inspectorMax = Math.Max(180, room - (sideShown ? 180 : 0));
        double inspectorWidth = inspectorShown ? Math.Min(inspector, inspectorMax) : 0;
        double sideMax = Math.Max(180, room - inspectorWidth);
        return (sideMax, inspectorMax);
    }

    private void SetPane(Border pane, GridSplitter splitter, ColumnDefinition column, bool shown, double width)
    {
        pane.Visibility = splitter.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        column.MinWidth = shown ? 180 : 0;
        column.Width = new GridLength(shown ? width : 0);
        LimitPaneWidths();
    }

    private void SideSplitter_Changed(object sender, RoutedEventArgs e)
    {
        if (e is KeyEventArgs { Key: not (Key.Left or Key.Right) }) return;
        _vm.SetSidePanelWidth(SideColumn.ActualWidth);
        LimitPaneWidths();
    }

    private void InspectorSplitter_Changed(object sender, RoutedEventArgs e)
    {
        if (e is KeyEventArgs { Key: not (Key.Left or Key.Right) }) return;
        _vm.SetInspectorWidth(InspectorColumn.ActualWidth);
        LimitPaneWidths();
    }

    private void SideSplitter_Reset(object sender, MouseButtonEventArgs e)
    {
        _vm.SetSidePanelWidth(AppPreferences.DefaultSidePanelWidth);
        SideColumn.Width = new GridLength(AppPreferences.DefaultSidePanelWidth);
        LimitPaneWidths();
    }

    private void InspectorSplitter_Reset(object sender, MouseButtonEventArgs e)
    {
        _vm.SetInspectorWidth(AppPreferences.DefaultInspectorWidth);
        InspectorColumn.Width = new GridLength(AppPreferences.DefaultInspectorWidth);
        LimitPaneWidths();
    }

    private void RailToggle_Click(object sender, RoutedEventArgs e) => ShowSidePanel(null);

    // The side pane has no room beside an open tool on a narrow window, so the tool gives way.
    private void ShowSidePanel(string? id)
    {
        if (!HandedIn()) return;
        if (_narrow && _vm.ActiveTool is not null) _vm.SelectTool(_vm.ActiveToolId);
        if (id is null) _vm.ToggleSidePanel();
        else _vm.SetSidePanel(id);
    }

    private void SidePaneClose_Click(object sender, RoutedEventArgs e)
    {
        if (HandedIn()) _vm.SetSidePanel(_vm.SidePanelId);
    }

    private void RefreshSidePane()
    {
        foreach (var (id, button) in _railButtons) button.IsChecked = id == _vm.SidePanelId;
        var tab = _vm.ActiveDocument;
        var info = ToolCatalog.FindSide(_vm.SidePanelId);
        if (tab is null || info is null)
        {
            SetPane(SidePane, SideSplitter, SideColumn, false, 0);
            _sidePanel?.Detach();
            _sidePanel = null;
            _sideTab = null;
            SideHost.Content = null;
            return;
        }
        if (_narrow && _vm.ActiveTool is not null)
        {
            SetPane(SidePane, SideSplitter, SideColumn, false, 0);
            return;
        }
        SetPane(SidePane, SideSplitter, SideColumn, true, _vm.SidePanelWidth);
        SideTitle.Text = info.Title;
        Place(info.Id, info.Create, SideHost, ref _sidePanel, ref _sideTab, tab);
    }

    private void RefreshInspector()
    {
        var tab = _vm.ActiveDocument;
        if (tab is null)
        {
            SetPane(Inspector, InspectorSplitter, InspectorColumn, false, 0);
            _inspectorPanel?.Detach();
            _inspectorPanel = null;
            _inspectorTab = null;
            InspectorHost.Content = null;
            return;
        }
        SetPane(Inspector, InspectorSplitter, InspectorColumn, _vm.ActiveTool is not null || (!_narrow && _vm.ShowFileInfo), _vm.InspectorWidth);
        if (_vm.ActiveTool is not { } tool)
        {
            _inspectorPanel?.Detach();
            _inspectorPanel = null;
            _inspectorTab = null;
            InspectorGlyph.Text = "\uE946";
            InspectorTitle.Text = Loc.T("File");
            InspectorClose.Visibility = Visibility.Visible;
            InspectorClose.ToolTip = Loc.T("Hide file information");
            AutomationProperties.SetName(InspectorClose, Loc.T("Hide file information"));
            InspectorHost.Content = DocumentSummary(tab);
            InspectorFooter.Visibility = Visibility.Collapsed;
            return;
        }
        InspectorGlyph.Text = tool.Glyph;
        InspectorTitle.Text = tool.Title;
        InspectorClose.Visibility = Visibility.Visible;
        InspectorClose.ToolTip = Loc.T("Close the tool");
        AutomationProperties.SetName(InspectorClose, Loc.T("Close the tool"));
        Place("tool:" + tool.Id, tool.Create, InspectorHost, ref _inspectorPanel, ref _inspectorTab, tab);
        RefreshAction();
    }

    // Shows the panel under <key> in the host, attached to the tab; the panel that was there is detached first.
    private void Place(string key, Func<ToolPanel> create, ContentControl host, ref ToolPanel? current, ref DocumentTab? attached, DocumentTab tab)
    {
        if (!_panels.TryGetValue(key, out var panel))
        {
            panel = create();
            _panels[key] = panel;
            panel.ActionChanged += (_, _) => RefreshAction();
        }
        if (ReferenceEquals(current, panel) && ReferenceEquals(attached, tab)) return;
        // The tab can change under the panel (open, close, Save all), so words still being typed go in before it lets go.
        current?.HandIn();
        current?.Detach();
        current = panel;
        attached = tab;
        host.Content = panel;
        panel.Attach(tab, _viewer, _vm);
    }

    private void RefreshAction()
    {
        if (_inspectorPanel?.Action is not { } action || _vm.ActiveTool is null)
        {
            InspectorFooter.Visibility = Visibility.Collapsed;
            return;
        }
        InspectorFooter.Visibility = Visibility.Visible;
        InspectorAction.Content = action.Text;
        LazyPDF.App.Icon.SetGlyph(InspectorAction, action.Glyph);
        InspectorAction.IsEnabled = action.CanRun();
        InspectorAction.ToolTip = action.Hint;
        AutomationProperties.SetHelpText(InspectorAction, action.Hint ?? "");
    }

    private async void InspectorAction_Click(object sender, RoutedEventArgs e)
    {
        if (_actionRunning || _inspectorPanel?.Action is not { } action) return;
        _actionRunning = true;
        InspectorAction.IsEnabled = false;
        TabBar.IsEnabled = false;
        try
        {
            await action.Run();
        }
        catch (OperationCanceledException)
        {
            _vm.SetStatus(Loc.T("Cancelled."));
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            _vm.ShowProblem(Problems.Tool(error, action.Text));
            System.Diagnostics.Trace.TraceError(error.ToString());
        }
        finally
        {
            _actionRunning = false;
            TabBar.IsEnabled = !Modal;
        }
        RefreshAction();
        ReleaseHeld();
    }

    private void InspectorClose_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.ActiveTool is null) _vm.SetShowFileInfo(false);
        else _vm.SelectTool(_vm.ActiveToolId);
        RefreshInspector();
    }

    private void FileInfo_Click(object sender, RoutedEventArgs e)
    {
        _vm.SetShowFileInfo(!_vm.ShowFileInfo);
        RefreshInspector();
    }

    // What the inspector shows while no tool is open: the facts of the file.
    private static UIElement DocumentSummary(DocumentTab tab)
    {
        var panel = new StackPanel { Margin = new Thickness(12, 4, 12, 12) };
        void Row(string label, string value)
        {
            panel.Children.Add(new TextBlock { Text = label, Style = (Style)Application.Current.FindResource("FieldLabelText") });
            panel.Children.Add(new TextBlock
            {
                Text = value,
                Style = (Style)Application.Current.FindResource("BodyText"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 12),
            });
        }

        var document = tab.Document;
        Row(Loc.T("File"), tab.Title);
        if (tab.Path is { } path) Row(Loc.T("Folder"), System.IO.Path.GetDirectoryName(path) ?? "");
        Row(Loc.T("Pages"), tab.PageCount.ToString());
        Row(Loc.T("PDF version"), document.Version);
        Row(Loc.T("Size"), Size(tab.Session.Current.Length));
        Row(Loc.T("Protection"), !document.IsEncrypted ? Loc.T("Not protected") : document.Security is { IsPublicKey: true } ? Loc.T("Protected for certificate holders") : Loc.T("Password protected"));
        if (document.IsSigned) Row(Loc.T("Signatures"), document.IsCertified ? Loc.T("Signed and certified") : Loc.T("Signed"));
        return panel;
    }

    private static string Size(long bytes) => bytes switch
    {
        < 1024 => Loc.T("{0} bytes", bytes),
        < 1024 * 1024 => Loc.T("{0} KB", Math.Round(bytes / 1024.0, 1)),
        _ => Loc.T("{0} MB", Math.Round(bytes / 1048576.0, 1)),
    };
}
