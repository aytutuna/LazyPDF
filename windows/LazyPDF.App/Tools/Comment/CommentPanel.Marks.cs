// What the panel does to the file: adding marks, changing the selected one, and the commit that makes each an undo step.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.FillSign;
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
        PdfAnnotation? made = null;
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
            case MarkTool.Stamp when _picture is { } picture:
                Added(Change(label, m =>
                {
                    made = m.AddPictureStamp(page, points[0], picture);
                    if (look.Opacity < 1) made = m.SetOpacity(made, look.Opacity);
                }), made);
                break;
            case MarkTool.Stamp:
                string stamp = StampValue();
                bool dated = StampDate.IsChecked == true;
                if (dated)
                {
                    look = look with { Color = look.Color ?? Marker.StampColor(stamp) };
                    stamp = AnnotationText.StampLabel(stamp) + " " + DateTime.Today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                }
                Added(Change(label, m => made = m.AddStamp(page, points[0], stamp, look, dated)), made);
                break;
            case MarkTool.Attach:
                _ = AttachAsync(page, points[0]);
                break;
            default:
                Added(Change(label, m => made = m.Add(tool, page, points, look)), made);
                break;
        }
    }

    // A mark just drawn stays selected, so a press on it moves it without changing the tool.
    private void Added(bool done, PdfAnnotation? made)
    {
        if (!done || made?.Reference is not { } reference || Tab is not { } tab) return;
        _edit?.Select(NewMarker(tab).Find(made.PageIndex, reference.Number));
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
        {
            PdfAnnotation? made = null;
            if (string.IsNullOrWhiteSpace(text)) return true;
            bool done = Change(label, m => made = m.Add(tool, page, points, look, text));
            Added(done, made);
            return done;
        });
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

    private void FillPictures()
    {
        var rows = new List<SavedRow>();
        foreach (var item in _pictures.List(SavedKind.Stamp))
        {
            if (_pictures.Load(item) is { } image) rows.Add(new SavedRow(item, SignatureArt.ToBitmap(image)));
        }
        PictureList.ItemsSource = rows;
        NonePictures.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        PictureList.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void PictureList_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        _picture = PictureList.SelectedItem is SavedRow row ? _pictures.Load(row.Item) : null;

    private async void AddPicture_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = Loc.T("Add a picture"), Filter = Loc.T("Pictures") + "|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff" };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        string path = dialog.FileName;
        PdfRgbaImage? image;
        try
        {
            image = await Task.Run(() =>
            {
                byte[] file = SignatureArt.UprightFile(File.ReadAllBytes(path));
                return new WicImageCodec().DecodeFile(file) is { Count: > 0 } frames ? SignatureArt.Shrink(frames[0], 600) : null;
            });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Host?.ShowProblem(Problems.Open(error, Path.GetFileName(path)));
            return;
        }
        if (image is null)
        {
            Host?.ShowProblem(new Problem(Loc.T("Choose a picture"), Loc.T("That file is not a picture Lazy PDF can read. Choose a PNG or JPEG.")));
            return;
        }
        var item = _pictures.Add(SavedKind.Stamp, image);
        FillPictures();
        PictureList.SelectedIndex = ((List<SavedRow>)PictureList.ItemsSource).FindIndex(r => r.Item == item);
    }

    private void RemovePicture_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not SavedRow row || Host is null) return;
        Host.ShowNotice(Loc.T("Delete this stamp?"), Loc.T("A saved copy cannot be brought back."), new NoticeAction(Loc.T("Delete"), () =>
        {
            _pictures.Remove(row.Item);
            FillPictures();
        }));
    }

    private async void Markup_Click(object sender, RoutedEventArgs e)
    {
        var kind = sender == MarkHighlight ? AnnotationType.Highlight : sender == MarkUnderline ? AnnotationType.Underline
            : sender == MarkStrikeOut ? AnnotationType.StrikeOut : AnnotationType.Squiggly;
        await MarkSelection(kind);
    }

    private async Task MarkSelection(AnnotationType kind)
    {
        if (Tab is not { } tab || Viewer is not { } viewer || !_allowed || MarkWork.Running) return;
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

    private void Edit_VertexMoved(PdfAnnotation mark, int index, Point to) => Change(Loc.T("Move point"), m => m.MovePoint(mark, index, to));

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
        if (e.Key == Key.Escape) _bar?.Hide();
        if (e.Key == Key.Escape && _active is DrawTool { Started: true } drawing)
        {
            drawing.Cancel();
            e.Handled = true;
        }
        else if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control && _active is DrawTool { Started: true } corners)
        {
            corners.Finish();
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
        LineStyleBox.IsEnabled = mark is null ? Marker.TakesLine(_tool) : Marker.TakesLine(mark);
        FillBox.IsEnabled = mark is null ? Marker.TakesFill(_tool) : Marker.TakesFill(mark);
        HeadRow.Visibility = (mark is null ? _tool == MarkTool.Arrow : HasHead(mark)) ? Visibility.Visible : Visibility.Collapsed;
        IconRow.Visibility = (mark is null ? _tool == MarkTool.Note : mark.Type == AnnotationType.Text) ? Visibility.Visible : Visibility.Collapsed;
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
            FontFamilyBox.SelectedItem = Families.Value.Contains(text.Family) ? text.Family : null;
            FontSizeBox.Text = Math.Round(text.Size, 1).ToString(CultureInfo.CurrentCulture);
            BoldToggle.IsChecked = text.Font.HasFlag(FontStyles.Bold);
            ItalicToggle.IsChecked = text.Font.HasFlag(FontStyles.Italic);
        }
        ShowColour(Marker.RgbOf(text is null ? mark.Color : text.TextColor ?? [0]));
        ShowFill(Marker.RgbOf(mark.InteriorColor));
        LineStyleBox.SelectedIndex = (int)Marker.LineOf(mark);
        HeadBox.SelectedIndex = Array.FindIndex(Heads, h => h.Value == mark.EndEnding);
        IconBox.SelectedIndex = Array.FindIndex(Icons, i => i.Value == mark.IconName);
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
        ShowFill(kept.Fill);
        LineStyleBox.SelectedIndex = (int)kept.Dash;
        HeadBox.SelectedIndex = Array.FindIndex(Heads, h => h.Value == kept.Head);
        IconBox.SelectedIndex = Array.FindIndex(Icons, i => i.Value == kept.Icon);
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

    // A fill the list does not have shows as no choice.
    private void ShowFill(double[]? rgb) =>
        FillBox.SelectedIndex = Array.FindIndex(Fills, f => f.Rgb is null ? rgb is null : rgb is not null && f.Rgb.Zip(rgb, (a, b) => Math.Abs(a - b)).All(d => d < 0.03));
}
