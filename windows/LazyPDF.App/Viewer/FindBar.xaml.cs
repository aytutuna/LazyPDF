using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>The find bar: types a query into the shared <see cref="ViewerSearch"/> and steps through its hits.</summary>
public partial class FindBar : UserControl
{
    private readonly DispatcherTimer _typing = new() { Interval = TimeSpan.FromMilliseconds(220) };
    private ViewerSearch? _search;

    public FindBar()
    {
        InitializeComponent();
        _typing.Tick += (_, _) =>
        {
            _typing.Stop();
            Run();
        };
    }

    /// <summary>Escape or the close button.</summary>
    public event EventHandler? CloseRequested;

    internal void Attach(ViewerSearch search)
    {
        _search = search;
        search.Changed += (_, _) => ShowCount();
    }

    /// <summary>Puts the cursor in the box with its text selected.</summary>
    public void Open(string? selection = null)
    {
        if (selection is { Length: > 0 } && !selection.Contains('\n') && selection != Query.Text) Query.Text = selection;
        Query.Focus();
        Query.SelectAll();
    }

    private void Run()
    {
        if (_search is null) return;
        _search.Start(Query.Text, new TextSearchOptions(CaseToggle.IsChecked == true, WordToggle.IsChecked == true, RegexToggle.IsChecked == true));
    }

    private void ShowCount()
    {
        if (_search is not { } search) return;
        string text;
        if (search.Query.Length == 0) text = "";
        else if (search.BadPattern) text = Loc.T("Not a valid pattern");
        else if (search.Hits.Count == 0) text = search.Running ? Loc.T("Searching") : Loc.T("No results");
        else if (search.Running) text = Loc.T("{0} found", search.Hits.Count);
        else text = Loc.T("{0} of {1}", search.Current + 1, search.Hits.Count);
        if (Count.Text != text)
        {
            Count.Text = text;
            var peer = UIElementAutomationPeer.FromElement(Count) ?? UIElementAutomationPeer.CreatePeerForElement(Count);
            peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
    }

    private void Query_TextChanged(object sender, TextChangedEventArgs e)
    {
        _typing.Stop();
        _typing.Start();
    }

    private void Query_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Enter:
                if (_typing.IsEnabled)
                {
                    _typing.Stop();
                    Run();
                }
                else if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) _search?.Previous();
                else _search?.Next();
                break;
            case Key.Escape:
                CloseRequested?.Invoke(this, EventArgs.Empty);
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    private void Option_Click(object sender, RoutedEventArgs e) => Run();

    private void Next_Click(object sender, RoutedEventArgs e) => _search?.Next();

    private void Previous_Click(object sender, RoutedEventArgs e) => _search?.Previous();

    private void Close_Click(object sender, RoutedEventArgs e) => CloseRequested?.Invoke(this, EventArgs.Empty);
}
