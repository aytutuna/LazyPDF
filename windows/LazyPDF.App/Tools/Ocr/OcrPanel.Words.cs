// The words of the text layer drawn over the pages in view, and the correction of the one that was clicked.
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Ocr;

public sealed partial class OcrPanel
{
    private readonly Dictionary<int, PageWords> _shown = [];
    private (int Page, int Index)? _picked;
    private bool _correcting;

    private sealed record PageWords(IReadOnlyList<OcrLayerWord> Words, List<Border> Boxes);

    // The word a signed file keeps waiting: where it is in the layer, what the layer says, what was typed and the revision of the file.
    private sealed record Waiting(int Page, int Index, string Origin, DisplayRect Box, string Text, int Revision);

    private static readonly ConditionalWeakTable<DocumentTab, Waiting> Kept = [];

    // What the layer says of the picked word, to tell whether the box holds a correction and to find the word again.
    private string _origin = "";
    private DisplayRect _originBox;

    private void AttachWords()
    {
        Viewer!.ViewChanged += Viewer_ViewChanged;
        if (Kept.TryGetValue(Tab!, out var back))
        {
            Kept.Remove(Tab!);
            Resume(Tab!, back);
        }
        ShowWords();
    }

    private void DetachWords()
    {
        var tab = Tab!;
        var back = Waited(tab, tab.Revision);
        Viewer!.ViewChanged -= Viewer_ViewChanged;
        HideWords();
        Pick(null);
        if (back is null) return;
        Kept.AddOrUpdate(tab, back);
        tab.PendingWords = 1;
    }

    private Waiting? Waited(DocumentTab tab, int revision) =>
        tab.PendingWords > 0 && _picked is { } word ? new Waiting(word.Page, word.Index, _origin, _originBox, WordBox.Text, revision) : null;

    // Puts a waiting word back in the box at once; its box on the page is marked when the page is drawn. After a change of the
    // file the word is found again by page, box and old text, or dropped.
    private void Resume(DocumentTab tab, Waiting back)
    {
        int index = back.Revision == tab.Revision ? back.Index : Find(tab, back);
        if (index < 0)
        {
            tab.PendingWords = 0;
            Host?.SetStatus(Loc.T("The word you were correcting is no longer in the file, so the correction was dropped."));
            return;
        }
        _picked = (back.Page, index);
        (_origin, _originBox) = (back.Origin, back.Box);
        WordBox.Text = back.Text;
        WordWhere.Text = Loc.T("Page {0}", back.Page + 1);
        WordEditor.Visibility = Visibility.Visible;
        WordHint.Visibility = Visibility.Collapsed;
        tab.PendingWords = 1;
    }

    private static int Find(DocumentTab tab, Waiting back)
    {
        if (back.Page >= tab.Document.Pages.Count) return -1;
        var found = PdfOcrLayer.Words(tab.Document, tab.Document.Pages[back.Page]).FirstOrDefault(w => w.Text == back.Origin && w.Box == back.Box);
        return found?.Index ?? -1;
    }

    private void Viewer_ViewChanged(object? sender, EventArgs e) => ShowWords();

    // The words and the boxes are for one revision of the file; the next change builds them again. A word waiting for an
    // answer is found again in the new layer.
    private void RefreshWords()
    {
        var tab = Tab;
        var waiting = tab is null ? null : Waited(tab, -1);
        HideWords();
        if (waiting is not null)
        {
            Pick(null);
            Resume(tab!, waiting);
        }
        ShowWords();
        if (waiting is null && _picked is { } picked) Pick(picked.Page, picked.Index, focus: false);
    }

    private void ShowWords()
    {
        var tab = Tab;
        var viewer = Viewer;
        if (tab is null || viewer is null || WordsToggle.IsChecked != true) return;
        foreach (int page in viewer.VisiblePages)
        {
            if (_shown.ContainsKey(page)) continue;
            var words = PdfOcrLayer.Words(tab.Document, tab.Document.Pages[page]);
            var boxes = new List<Border>(words.Count);
            _shown[page] = new PageWords(words, boxes);
            if (words.Count == 0) continue;
            var overlay = viewer.Overlay(page);
            foreach (var word in words)
            {
                var box = new Border
                {
                    Width = word.Box.Width,
                    Height = word.Box.Height,
                    BorderThickness = new Thickness(0.75),
                    Background = Brushes.Transparent,
                    Opacity = 0.8,
                    Cursor = Cursors.Hand,
                    Tag = (page, word.Index),
                };
                box.SetResourceReference(Border.BorderBrushProperty, "AccentFillColorDefaultBrush");
                System.Windows.Automation.AutomationProperties.SetName(box, word.Text);
                box.MouseLeftButtonDown += Word_MouseLeftButtonDown;
                Canvas.SetLeft(box, word.Box.X);
                Canvas.SetTop(box, word.Box.Y);
                overlay.Children.Add(box);
                boxes.Add(box);
            }
            if (_picked is { } now && now.Page == page && now.Index < boxes.Count) Mark(boxes[now.Index], true);
        }
        FillWordList();
    }

    private void HideWords()
    {
        if (Viewer is { } viewer)
        {
            foreach (var (page, shown) in _shown)
            {
                foreach (var box in shown.Boxes) viewer.Overlay(page).Children.Remove(box);
            }
        }
        _shown.Clear();
        FillWordList();
    }

    // The words of the page in view as a list too, for whoever cannot point at them.
    private void FillWordList()
    {
        var shown = Viewer is { } viewer && WordsToggle.IsChecked == true && _shown.TryGetValue(viewer.PageIndex, out var page) ? page.Words : null;
        _filling = true;
        if (!ReferenceEquals(WordList.ItemsSource, shown)) WordList.ItemsSource = shown;
        WordList.SelectedIndex = shown is not null && _picked is { } picked && picked.Page == Viewer!.PageIndex ? picked.Index : -1;
        _filling = false;
        WordList.Visibility = shown is { Count: > 0 } ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Word_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        var (page, index) = ((int, int))((Border)sender).Tag;
        Pick(page, index, focus: true);
        e.Handled = true;
    }

    private void Pick(int page, int index, bool focus) => Pick((page, index), focus);

    private void Pick((int Page, int Index)? word, bool focus = false)
    {
        if (Tab is { } shownTab) shownTab.PendingWords = 0;
        if (_picked is { } old && _shown.TryGetValue(old.Page, out var before) && old.Index < before.Boxes.Count) Mark(before.Boxes[old.Index], false);
        _picked = null;
        if (word is { } next && _shown.TryGetValue(next.Page, out var shown) && next.Index < shown.Words.Count)
        {
            _picked = next;
            Mark(shown.Boxes[next.Index], true);
            WordBox.Text = _origin = shown.Words[next.Index].Text;
            _originBox = shown.Words[next.Index].Box;
            WordWhere.Text = Loc.T("Page {0}", next.Page + 1);
            if (focus) EditWord();
        }
        WordEditor.Visibility = _picked is null ? Visibility.Collapsed : Visibility.Visible;
        WordHint.Visibility = _picked is null ? Visibility.Visible : Visibility.Collapsed;
        FillWordList();
    }

    private void EditWord()
    {
        WordBox.Focus();
        WordBox.SelectAll();
    }

    private static void Mark(Border box, bool picked)
    {
        box.Opacity = picked ? 1 : 0.8;
        box.BorderThickness = new Thickness(picked ? 2 : 0.75);
        // Light enough to read the scan under it.
        box.Background = picked && Application.Current.TryFindResource("AccentFillColorDefaultBrush") is SolidColorBrush accent
            ? new SolidColorBrush(Color.FromArgb(0x30, accent.Color.R, accent.Color.G, accent.Color.B))
            : Brushes.Transparent;
    }

    private void WordsToggle_Click(object sender, RoutedEventArgs e)
    {
        if (WordsToggle.IsChecked == true) ShowWords();
        else
        {
            HideWords();
            Pick(null);
        }
    }

    private void WordApply_Click(object sender, RoutedEventArgs e) => ApplyWord();

    private void WordBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        ApplyWord();
        e.Handled = true;
    }

    private void WordList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_filling && WordList.SelectedIndex >= 0 && Viewer is { } viewer) Pick(viewer.PageIndex, WordList.SelectedIndex, focus: false);
    }

    private void WordList_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || _picked is null) return;
        EditWord();
        e.Handled = true;
    }

    private void ApplyWord()
    {
        if (Tab is not { } tab || Host is not { } host || _picked is not { } word) return;
        string text = WordBox.Text.Trim();
        if (OcrWork.Cleared(tab, host, () => ApplyAnyway(tab, word, text))) Apply(tab, word, text);
    }

    // A word typed and not yet in the file goes in before the file is saved, undone or closed. A signed file keeps it in the
    // box, as Measure keeps its readings: nothing is written without the user's answer, and the close question names it.
    // The word stays with its tab when another tab or tool is shown, so moving on loses nothing.
    public override bool HandIn()
    {
        if (Tab is not { } tab || Host is not { } host) return true;
        tab.PendingWords = 0;
        if (_picked is not { } word) return true;
        string text = WordBox.Text.Trim();
        if (text == _origin) return true;
        bool refused = OcrWork.Refusal(tab.Document) is not null;
        if (tab.Document.IsSigned && !refused)
        {
            tab.PendingWords = 1;
            return true;
        }
        if (OcrWork.Cleared(tab, host, () => ApplyAnyway(tab, word, text))) Apply(tab, word, text);
        else tab.PendingWords = refused ? 0 : 1;
        return true;
    }

    private void ApplyAnyway(DocumentTab tab, (int Page, int Index) word, string text)
    {
        if (ReferenceEquals(Tab, tab)) Apply(tab, word, text);
    }

    private void Apply(DocumentTab tab, (int Page, int Index) word, string text)
    {
        tab.PendingWords = 0;
        _correcting = true;
        try
        {
            OcrWork.Correct(tab, word.Page, word.Index, text);
        }
        finally
        {
            _correcting = false;
        }
        if (text.Length == 0) Pick(null);
        // Off the text box, so that Ctrl+Z undoes the correction and not the typing.
        (WordEditor.Visibility == Visibility.Visible ? (Control)WordApplyButton : WordsToggle).Focus();
    }
}
