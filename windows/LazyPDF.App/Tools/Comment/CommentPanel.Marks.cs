// What the panel does to the file: adding marks, changing the selected one, and the commit that makes each an undo step.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using FontStyles = LazyPDF.Core.FontStyles;

namespace LazyPDF.App.Tools.Comment;

public partial class CommentPanel
{
    private const double EraserReach = 4;
    private const long MaxAttachment = 50 * 1024 * 1024;

    // False when the file refused the change and the user was told; a change the panel does not take at the moment counts as done.
    private bool Change(string label, Action<Marker> work)
    {
        if (Tab is not { } tab || Host is not { } host || !_allowed || MarkWork.Running) return true;
        try
        {
            work(NewMarker(tab));
        }
        catch (InvalidOperationException error) when (error.Message == AnnotationText.NoFont)
        {
            Restore(tab);
            host.ShowProblem(new Problem(Loc.T("Text not drawn"), AnnotationText.NoFont));
            return false;
        }
        catch (ArgumentException)
        {
            Restore(tab);
            host.ShowProblem(new Problem(Loc.T("Nothing to draw"), Loc.T("That mark has no area. Drag farther and try again.")));
            return false;
        }
        if (MarkWork.Commit(tab, host, label)) return true;
        _edit?.Refresh();
        return false;
    }

    // Puts the file back as it was after a change failed halfway.
    private void Restore(DocumentTab tab)
    {
        tab.Session.Discard();
        _edit?.Refresh();
    }

    private void Drew(MarkTool tool, int page, IReadOnlyList<Point> points)
    {
        if (!_allowed || MarkWork.Running) return;
        var look = CurrentStyle();
        string label = tool == MarkTool.Eraser ? Loc.T("Erase") : Tools.First(t => t.Tool == tool).Text;
        switch (tool)
        {
            case MarkTool.Eraser:
                Change(label, m =>
                {
                    foreach (var mark in m.Along(page, points, EraserReach).Where(Marker.Erasable)) m.Delete(mark);
                });
                break;
            case MarkTool.Note or MarkTool.TextBox or MarkTool.Callout:
                Type(tool, page, points, look);
                break;
            case MarkTool.Stamp:
                Change(label, m => m.AddStamp(page, points[0], StampValue(), look));
                break;
            case MarkTool.Attach:
                _ = AttachAsync(page, points[0]);
                break;
            default:
                Change(label, m => m.Add(tool, page, points, look));
                break;
        }
    }

    private string StampValue()
    {
        string typed = StampName.Text.Trim();
        return AnnotationText.StandardStamps.FirstOrDefault(name => AnnotationText.StampLabel(name).Equals(typed, StringComparison.CurrentCultureIgnoreCase)) ?? typed;
    }

    private void Type(MarkTool tool, int page, IReadOnlyList<Point> points, MarkStyle look)
    {
        if (Tab is not { } tab || Viewer is not { } viewer) return;
        var area = tool == MarkTool.Note ? new Rect(points[0].X, points[0].Y + Marker.NoteSize, 170, 60) : Marker.BoxOf(tool, points);
        string label = Tools.First(t => t.Tool == tool).Text;
        Compose(tab, viewer.Overlay(page), area, tool == MarkTool.Note ? 12 : look.Size, "", text =>
            string.IsNullOrWhiteSpace(text) || Change(label, m => m.Add(tool, page, points, look, text)));
    }

    // The box opens again with the text when the file would not take it, so that nothing typed is lost.
    private void Compose(DocumentTab tab, PageOverlay overlay, Rect area, double size, string text, Func<string, bool> keep)
    {
        _editor = TextEditor.Open(overlay, area, size, text, typed =>
        {
            _editor = null;
            if (typed is null || !ReferenceEquals(Tab, tab) || keep(typed)) return;
            Dispatcher.BeginInvoke(() =>
            {
                if (ReferenceEquals(Tab, tab)) Compose(tab, overlay, area, size, typed, keep);
            });
        });
    }

    private async Task AttachAsync(int page, Point at)
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = Loc.T("Attach file") };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        string path = dialog.FileName;
        string name = Path.GetFileName(path);
        var tooBig = new Problem(Loc.T("File too large"), Loc.T("{0} is over 50 MB. Attach a smaller file.", name));
        try
        {
            if (new FileInfo(path).Length > MaxAttachment)
            {
                host.ShowProblem(tooBig);
                return;
            }
            var marker = NewMarker(tab);
            if (await WorkAsync(tab, host, Loc.T("Attaching file"), _ => marker.AddAttachment(page, at, name, File.ReadAllBytes(path))))
            {
                MarkWork.Commit(tab, host, Loc.T("Attach file"));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(Problems.Open(error, name));
        }
        catch (OutOfMemoryException)
        {
            host.ShowProblem(tooBig);
        }
    }

    private async void Markup_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Viewer is not { } viewer || !_allowed || MarkWork.Running) return;
        var kind = sender == MarkHighlight ? AnnotationType.Highlight : sender == MarkUnderline ? AnnotationType.Underline
            : sender == MarkStrikeOut ? AnnotationType.StrikeOut : AnnotationType.Squiggly;
        var runs = await viewer.GetSelectionAsync();
        if (!ReferenceEquals(Tab, tab)) return;
        if (runs.Count == 0)
        {
            Host?.SetStatus(Loc.T("Select some text first."));
            return;
        }
        var look = CurrentStyle();
        Change(AnnotationText.KindName(kind), m => m.Markup(kind, runs, look));
        viewer.ClearSelection();
    }

    private void Edit_SelectionChanged(object? sender, EventArgs e) => ShowSelected();

    private void Edit_Moved(PdfAnnotation mark, Vector shift) => Change(Loc.T("Move"), m => m.Move(mark, shift));

    private void Edit_Resized(PdfAnnotation mark, Rect box) => Change(Loc.T("Resize"), m => m.Resize(mark, box));

    private void Edit_EditRequested(PdfAnnotation mark) => EditTextOf(mark);

    private void EditText_Click(object sender, RoutedEventArgs e)
    {
        if (_edit?.Current is { } mark) EditTextOf(mark);
    }

    private void EditTextOf(PdfAnnotation mark)
    {
        if (Tab is not { } tab || Viewer is not { } viewer || !_allowed || MarkWork.Running) return;
        var box = new Marker(tab.Document, _fonts, "", DateTimeOffset.Now).BoxOf(mark);
        var area = mark.Type == AnnotationType.Text ? new Rect(box.X, box.Bottom, 170, 60) : box;
        _editor?.Drop();
        Compose(tab, viewer.Overlay(mark.PageIndex), area, mark.Type == AnnotationType.FreeText ? Marker.TextOf(mark).Size : 12, mark.Contents ?? "", text =>
            text == mark.Contents || Change(Loc.T("Edit text"), m => m.SetText(mark, text)));
    }

    private void DeleteMark_Click(object sender, RoutedEventArgs e) => DeleteSelected();

    private void DeleteSelected()
    {
        if (_edit?.Current is { } mark) Change(Loc.T("Delete"), m => m.Delete(mark));
    }

    private void View_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.FocusedElement is TextBox) return;
        if (e.Key == Key.Escape && _active is DrawTool { Started: true } drawing)
        {
            drawing.Cancel();
            e.Handled = true;
        }
        else if (e.Key == Key.Delete && _edit?.Current is not null)
        {
            DeleteSelected();
            e.Handled = true;
        }
    }

    private void ShowSelected()
    {
        var mark = _edit?.Current;
        SelectedRow.Visibility = mark is null ? Visibility.Collapsed : Visibility.Visible;
        if (mark is null)
        {
            if (_drawing is { } kept) RestoreDrawing(kept);
            return;
        }
        _drawing ??= CurrentStyle();
        SelectedTitle.Text = Loc.T("Selected: {0}", AnnotationText.KindName(mark.Type));
        EditText.IsEnabled = mark.Type is AnnotationType.Text or AnnotationType.FreeText || mark.Contents is { Length: > 0 };
        _loading = true;
        WidthSlider.Value = Math.Clamp(mark.Border.Width, WidthSlider.Minimum, WidthSlider.Maximum);
        OpacitySlider.Value = Math.Clamp(Math.Round(mark.Opacity * 20) * 5, OpacitySlider.Minimum, OpacitySlider.Maximum);
        var text = mark.Type == AnnotationType.FreeText ? Marker.TextOf(mark) : null;
        if (text is not null)
        {
            FontFamilyBox.SelectedItem = Families.Contains(text.Family) ? text.Family : null;
            FontSizeBox.Text = Math.Round(text.Size, 1).ToString(CultureInfo.CurrentCulture);
            BoldToggle.IsChecked = text.Font.HasFlag(FontStyles.Bold);
            ItalicToggle.IsChecked = text.Font.HasFlag(FontStyles.Italic);
        }
        ShowColour(Marker.RgbOf(text is null ? mark.Color : text.TextColor ?? [0]));
        _loading = false;
        ShowReadouts();
    }

    // Looking at a mark must not change the look of the next one drawn.
    private void RestoreDrawing(MarkStyle kept)
    {
        _loading = true;
        WidthSlider.Value = kept.Width;
        OpacitySlider.Value = kept.Opacity * 100;
        ShowColour(kept.Color);
        FontFamilyBox.SelectedItem = kept.Family;
        FontSizeBox.Text = kept.Size.ToString(CultureInfo.CurrentCulture);
        BoldToggle.IsChecked = kept.Font.HasFlag(FontStyles.Bold);
        ItalicToggle.IsChecked = kept.Font.HasFlag(FontStyles.Italic);
        _drawing = null;
        _loading = false;
        ShowReadouts();
    }

    // The swatch that matches the mark's colour is checked, and becomes the colour the next mark takes.
    private void ShowColour(double[]? rgb)
    {
        foreach (RadioButton swatch in Swatches.Children)
        {
            swatch.IsChecked = rgb is null ? swatch.Tag is "auto" : swatch.Tag is double[] want && want.Zip(rgb, (a, b) => Math.Abs(a - b)).All(d => d < 0.03);
        }
        _color = rgb;
    }
}
