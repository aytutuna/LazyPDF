using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

// The figures of the file, each with its picture beside the box for its description.
public partial class AccessibilityPanel
{
    private int _pictureTicket;

    // Text typed for a figure and not saved yet, by the figure's key, so moving to another figure does not lose it.
    private readonly Dictionary<int, string> _drafts = [];

    // The figure to show when the list is built: the one that was shown, or the next one after a save.
    private int _figureNumber;

    private FigureRow? Selected => FigureList.SelectedItem as FigureRow;

    private void RenderFigures()
    {
        var rows = _figures;
        FigureList.ItemsSource = rows;
        FigureList.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        int bare = rows.Count(r => !r.HasDescription);
        FiguresNote.Text = _treeFailed ? Loc.T("The tags could not be read.")
            : _tree is null ? Loc.T("The file has no tags, so no figures are known. Add tags first.")
            : _tree.IsTruncated ? Loc.T("The tags are too large to list every figure.")
            : rows.Count == 0 ? Loc.T("The file has no figures.")
            : bare == 0 ? Loc.T("Every figure has a description.")
            : Loc.T("{0} of {1} figures have no description.", bare, rows.Count);
        if (rows.Count == 0) return;
        int keep = _figureNumber - 1;
        FigureList.SelectedIndex = keep >= 0 && keep < rows.Count ? keep : Math.Max(rows.ToList().FindIndex(r => !r.HasDescription), 0);
    }

    private void FigureList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var row = Selected;
        var shown = row is null ? Visibility.Collapsed : Visibility.Visible;
        FigureEditor.Visibility = shown;
        FigureButtons.Visibility = shown;
        if (row is null) return;
        _figureNumber = row.Number;
        AltBox.Text = _drafts.TryGetValue(row.Key, out string? draft) ? draft : row.Alt;
        RememberDraft();
        NextBare.IsEnabled = _figures.Any(r => !r.HasDescription);
        if (row.Page >= 0) Viewer?.GoToPage(row.Page);
        _ = ShowPictureAsync(row);
    }

    private async Task ShowPictureAsync(FigureRow row)
    {
        var tab = Tab!;
        var copy = _treeCopy;
        int ticket = ++_pictureTicket;
        FigurePicture.Source = null;
        FigureNoPicture.Visibility = Visibility.Collapsed;
        BitmapSource? picture = null;
        if (copy is not null && tab.Renderer is WindowsPageRenderer renderer)
        {
            // The copy is read by one picture at a time, and a picture nobody waits for any more is not looked for.
            var box = await Task.Run(() =>
            {
                lock (copy) return ticket == _pictureTicket ? FigureFinder.Box(copy, row.Element, row.Page) : null;
            });
            if (box is { } found && ticket == _pictureTicket)
            {
                var region = new DisplayRect(found.X - 4, found.Y - 4, found.Width + 8, found.Height + 8);
                double dpi = Math.Clamp(200 * 72 / region.Width, 36, 288);
                if (await renderer.RenderRegionAsync(row.Page, region, dpi) is { } image) picture = Pixels.ToBitmap(image);
            }
        }
        if (ticket != _pictureTicket) return;
        FigurePicture.Source = picture;
        FigureNoPicture.Visibility = picture is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void AltBox_TextChanged(object sender, TextChangedEventArgs e) => RememberDraft();

    private void RememberDraft()
    {
        if (Selected is not { } row)
        {
            SaveAlt.IsEnabled = false;
            return;
        }
        bool changed = AltBox.Text.Trim() != row.Alt;
        if (changed) _drafts[row.Key] = AltBox.Text;
        else _drafts.Remove(row.Key);
        SaveAlt.IsEnabled = changed;
    }

    private async void SaveAlt_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } row || Tab is not { } tab) return;
        string text = AltBox.Text;
        await ChangeGate.RunAsync(tab, Host!, Loc.T("Figure description"), () =>
        {
            if (!ReferenceEquals(tab, Tab)) return Task.CompletedTask;
            try
            {
                // The tree on the screen was read from a copy; the edit goes to the open document's own.
                var tree = StructureTree.Read(tab.Document);
                var figure = tree is null ? null : FigureFinder.List(tree).ElementAtOrDefault(row.Number - 1);
                if (tree is null || AccessibilityEdits.FigureChanged(figure?.Element, row.Alt))
                {
                    Host!.ShowProblem(new Problem(Loc.T("Description not saved"), Loc.T("The figure is no longer in the file.")));
                    return Task.CompletedTask;
                }
                AccessibilityEdits.SetAlt(tab.Document, tree, figure!.Element, text);
                if (tab.Commit(Loc.T("Figure description"))) Host!.SetStatus(Loc.T("Description saved."));
            }
            catch (Exception error) when (error is InvalidOperationException or PdfReadException)
            {
                tab.Session.Discard();
                Host!.ShowProblem(new Problem(Loc.T("Description not saved"), Loc.T("The tags of this file are too large to change here.")));
                return Task.CompletedTask;
            }
            _drafts.Remove(row.Key);
            _figureNumber = text.Trim().Length > 0 ? NextBareAfter(row.Number, row.Number) : row.Number;
            return Task.CompletedTask;
        });
    }

    private void NextBare_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } row) return;
        int number = NextBareAfter(row.Number, 0);
        FigureList.SelectedIndex = number - 1;
        FigureList.ScrollIntoView(_figures[number - 1]);
    }

    // The number of the next figure with no description, wrapping round, and counting the one just saved as described.
    private int NextBareAfter(int number, int saved)
    {
        for (int step = 1; step <= _figures.Count; step++)
        {
            int index = (number - 1 + step) % _figures.Count;
            if (index + 1 != saved && !_figures[index].HasDescription) return index + 1;
        }
        return number;
    }
}
