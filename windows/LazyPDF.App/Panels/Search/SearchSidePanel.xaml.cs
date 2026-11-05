using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Tools;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Panels.Search;

/// <summary>The hits of the find bar's search, with the words around each; a click goes to the hit.</summary>
public partial class SearchSidePanel : ToolPanel
{
    private bool _syncing;

    public SearchSidePanel() => InitializeComponent();

    protected override void OnAttach()
    {
        var search = Viewer!.Search;
        search.Changed += Search_Changed;
        Results.ItemsSource = search.Hits;
        Search_Changed(search, EventArgs.Empty);
    }

    protected override void OnDetach()
    {
        Viewer!.Search.Changed -= Search_Changed;
        Results.ItemsSource = null;
    }

    private void Search_Changed(object? sender, EventArgs e)
    {
        var search = Viewer!.Search;
        Summary.Text = search.Query.Length == 0 ? Loc.T("Search the file to list every match here.")
            : search.BadPattern ? Loc.T("Not a valid pattern")
            : search.Running ? Loc.T("Searching for {0}", search.Query)
            : search.Hits.Count == 0 ? Loc.T("No results for {0}", search.Query)
            : Loc.Plural(search.Hits.Count, "{0} result for {1}", "{0} results for {1}", search.Hits.Count, search.Query);
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

    // The viewer is out of the tree while a tool holds the stage, so its find bar would open unseen.
    private void Find_Click(object sender, RoutedEventArgs e)
    {
        if (Viewer is { View.IsVisible: true } viewer) viewer.ShowFind();
    }
}
