using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPDF.App.Tools;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Panels.Search;

/// <summary>The hits of the find bar's search, with the words around each; a click goes to the hit.</summary>
public partial class SearchSidePanel : ToolPanel
{
    private readonly DispatcherTimer _typing = new() { Interval = TimeSpan.FromMilliseconds(220) };
    private bool _syncing;
    private bool _following;
    private ListBoxItem? _pressed;
    private bool _pressedSelected;

    public SearchSidePanel()
    {
        InitializeComponent();
        _typing.Tick += (_, _) =>
        {
            _typing.Stop();
            Run();
        };
    }

    protected override void OnAttach()
    {
        var search = Viewer!.Search;
        search.Changed += Search_Changed;
        Viewer.View.IsVisibleChanged += View_IsVisibleChanged;
        Results.ItemsSource = search.Hits;
        Search_Changed(search, EventArgs.Empty);
    }

    protected override void OnDetach()
    {
        _typing.Stop();
        Viewer!.Search.Changed -= Search_Changed;
        Viewer.View.IsVisibleChanged -= View_IsVisibleChanged;
        Results.ItemsSource = null;
    }

    private void View_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e) => ShowStageNote();

    private void ShowStageNote() => StageNote.Visibility = Viewer!.View.IsVisible ? Visibility.Collapsed : Visibility.Visible;

    private void Search_Changed(object? sender, EventArgs e)
    {
        var search = Viewer!.Search;
        ShowStageNote();
        if (!_typing.IsEnabled && !Query.IsKeyboardFocused && Query.Text != search.Query)
        {
            _following = true;
            Query.Text = search.Query;
            _following = false;
        }
        Summary.Text = search.Query.Length == 0 ? Loc.T("Search the file to list every match here.")
            : search.BadPattern ? Loc.T("Not a valid pattern")
            : search.Running && search.Hits.Count > 0 ? Loc.T("{0} found", search.Hits.Count)
            : search.Running ? Loc.T("Searching for {0}", search.Query)
            : search.Hits.Count == 0 && TimedOutText.For(search.TimedOut) is { } slow ? slow
            : search.NoText ? Loc.T("This file has no text to search. Try Make searchable.")
            : search.Hits.Count == 0 ? Loc.T("No results for {0}", search.Query)
            : Loc.Plural(search.Hits.Count, "{0} result for {1}", "{0} results for {1}", search.Hits.Count, search.Query);
        if (search.Hits.Count > 0 && TimedOutText.For(search.TimedOut) is { } more) Summary.Text += " " + more;
        if (Results.SelectedIndex == search.Current) return;
        _syncing = true;
        Results.SelectedIndex = search.Current;
        _syncing = false;
        if (Results.SelectedItem is not null) Results.ScrollIntoView(Results.SelectedItem);
    }

    private void Results_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncing && Results.SelectedIndex >= 0) Viewer?.Search.Select(Results.SelectedIndex);
    }

    // Clicking the hit that is already current raises no SelectionChanged, so the click goes to it here.
    private void Results_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        _pressed = ItemsControl.ContainerFromElement(Results, (DependencyObject)e.OriginalSource) as ListBoxItem;
        _pressedSelected = _pressed?.IsSelected == true;
    }

    private void Results_PreviewMouseUp(object sender, MouseButtonEventArgs e)
    {
        var item = ItemsControl.ContainerFromElement(Results, (DependencyObject)e.OriginalSource) as ListBoxItem;
        if (item is not null && item == _pressed && _pressedSelected)
            Viewer?.Search.Select(Results.ItemContainerGenerator.IndexFromContainer(item));
        _pressed = null;
    }

    private void Run() => Viewer?.Search.Start(Query.Text, Viewer.Search.Options);

    private void Query_TextChanged(object sender, TextChangedEventArgs e)
    {
        QueryHint.Visibility = Query.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_following) return;
        _typing.Stop();
        _typing.Start();
    }

    private void Query_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        if (_typing.IsEnabled || Query.Text != Viewer?.Search.Query)
        {
            _typing.Stop();
            Run();
        }
        else if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) Viewer?.Search.Previous();
        else Viewer?.Search.Next();
        e.Handled = true;
    }

    // The viewer is out of the tree while a tool holds the stage, so its find bar would open unseen.
    private void Find_Click(object sender, RoutedEventArgs e)
    {
        if (Viewer is { View.IsVisible: true } viewer) viewer.ShowFind();
        else Host?.SetStatus(Loc.T("Close the tool to use the search bar."));
    }
}
