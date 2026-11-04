using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using Microsoft.Win32;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.EditContent;

// Pictures and shapes: replace, save, crop, colours, opacity, order, turning, deleting and adding pictures.
public sealed partial class EditContentPanel
{
    private static string PictureFilter => Loc.T("Pictures") + "|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.tif;*.tiff;*.heic;*.webp|" + Loc.T("All files") + "|*.*";

    private readonly DispatcherTimer _opacityTimer = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private int _opacityPage;
    private IReadOnlyList<int> _opacityIds = [];
    private double _opacityValue;

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (_surface is not { Selected.Count: > 0 } surface) return;
        int page = surface.Page;
        var ids = surface.Selected.ToList();
        if (Apply(() => _edits!.Delete(page, ids), Loc.T("Deleted."))) surface.Clear();
    }

    private void Rotate_Click(object sender, RoutedEventArgs e)
    {
        if (_surface is not { Selected.Count: > 0 } surface) return;
        int page = surface.Page;
        var ids = surface.Selected.ToList();
        double degrees = sender == RotateLeft ? 90 : -90;
        Apply(() => _edits!.Rotate(page, ids, degrees), Loc.T("Turned."));
    }

    private void Flip_Click(object sender, RoutedEventArgs e)
    {
        if (_surface is not { Selected.Count: > 0 } surface) return;
        int page = surface.Page;
        var ids = surface.Selected.ToList();
        bool across = sender == FlipAcross;
        Apply(() => _edits!.Flip(page, ids, across, Viewer!.Rotation), Loc.T("Flipped."));
    }

    private void Order_Click(object sender, RoutedEventArgs e)
    {
        if (_surface is not { Selected: [int id] } surface || _edits!.Object(surface.Page, id) is not { } o) return;
        int page = surface.Page;
        var move = sender == ToFront ? OrderMove.Front : sender == Forward ? OrderMove.Forward : sender == Backward ? OrderMove.Backward : OrderMove.Back;
        if (!Apply(() => _edits!.Order(page, id, move), Loc.T("Order changed."))) return;

        // The object keeps its place on the page but not its number; it is the one of its kind with the same box.
        var same = _edits.Editor(page).Objects.Where(x => x.Kind == o.Kind && x.Bounds == o.Bounds).Select(x => x.Id).ToList();
        if (same.Count > 0) surface.Select(page, [move is OrderMove.Front or OrderMove.Forward ? same.Max() : same.Min()]);
    }

    private void ReplaceImage_Click(object sender, RoutedEventArgs e)
    {
        if (_surface is not { Selected: [int id] } surface) return;
        var dialog = new OpenFileDialog { Filter = PictureFilter, Title = Loc.T("Replace the picture") };
        if (dialog.ShowDialog() != true) return;
        int page = surface.Page;
        byte[]? file = ReadPicture(dialog.FileName);
        if (file is not null) Apply(() => _edits!.ReplaceImage(page, id, file), Loc.T("Picture replaced."));
    }

    private void ExtractImage_Click(object sender, RoutedEventArgs e)
    {
        if (_surface is not { Selected: [int id] } surface) return;
        if (_edits!.Extract(surface.Page, id) is not { } picture)
        {
            ShowMessage("", EditingText.NoImage, caution: true);
            return;
        }
        var dialog = new SaveFileDialog { FileName = "picture." + picture.Extension, Filter = "*." + picture.Extension + "|*." + picture.Extension, Title = Loc.T("Save the picture") };
        if (dialog.ShowDialog() != true) return;
        try
        {
            System.IO.File.WriteAllBytes(dialog.FileName, picture.Data);
            Host?.SetStatus(Loc.T("Picture saved."));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Host?.ShowProblem(new Problem(Loc.T("Picture not saved"), Loc.T("{0} could not be written. Choose another folder.", System.IO.Path.GetFileName(dialog.FileName))));
        }
    }

    private void CropImage_Click(object sender, RoutedEventArgs e)
    {
        FinishPending();
        _surface!.Mode = EditMode.Crop;
        RefreshPanel();
    }

    private void Crop(int page, PdfRect area)
    {
        _surface!.Mode = EditMode.Select;
        if (_surface is { Selected: [int id] } && _surface.Page == page && _edits!.Object(page, id) is ImageObject image)
        {
            var kept = image.Bounds.Intersect(area);
            if (!kept.IsEmpty)
            {
                Apply(() => _edits.Crop(page, id, kept), Loc.T("Picture cropped."));
                return;
            }
        }
        RefreshPanel();
    }

    private void AddPicture_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = PictureFilter, Title = Loc.T("Add a picture") };
        if (dialog.ShowDialog() != true || ReadPicture(dialog.FileName) is not { } file) return;
        FinishPending();
        int page = Viewer!.PageIndex;
        var size = Viewer.PageSize(page);
        double width = size.Width * 0.5, height = size.Height * 0.5;
        var box = Viewer.Geometry(page).ToUser(new DisplayRect((size.Width - width) / 2, (size.Height - height) / 2, width, height));
        if (!Apply(() => _edits!.AddImage(page, box, file), Loc.T("Picture added."))) return;
        if (_edits!.Editor(page).Objects is [.., ImageObject last]) _surface!.Select(page, [last.Id]);
    }

    private byte[]? ReadPicture(string path)
    {
        try
        {
            return System.IO.File.ReadAllBytes(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            ShowMessage("", Loc.T("{0} could not be read. Check that the file is still there.", System.IO.Path.GetFileName(path)), caution: true);
            return null;
        }
    }

    // ----- Shapes and opacity

    private void ShapeStyle(RgbColor? fill, RgbColor? stroke, double? width)
    {
        if (_surface is not { Selected.Count: > 0 } surface) return;
        int page = surface.Page;
        var ids = surface.Selected.ToList();
        Apply(() => _edits!.PathStyle(page, ids, fill, stroke, width), Loc.T("Shape changed."));
    }

    private void WidthBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (_loading || SelectedObjects() is not [PathObject path]) return;
        if (!TryNumber(WidthBox.Text, 0, 200, out double width)) WidthBox.Text = Number(path.LineWidth);
        else if (Math.Abs(width - path.LineWidth) > 0.05) ShapeStyle(null, null, width);
    }

    // The slider settles for a moment before it is applied, to what it was moved on and not to what was chosen since.
    private void Opacity_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_loading || _surface is not { Selected.Count: > 0 } surface) return;
        OpacityReadout.Text = Loc.T("{0}%", (int)OpacitySlider.Value);
        if (!_opacityTimer.IsEnabled) (_opacityPage, _opacityIds) = (surface.Page, [.. surface.Selected]);
        _opacityValue = OpacitySlider.Value / 100;
        _opacityTimer.Stop();
        _opacityTimer.Start();
    }

    private void OpacityTimer_Tick(object? sender, EventArgs e)
    {
        _opacityTimer.Stop();
        if (_edits is null) return;
        int page = _opacityPage;
        var ids = _opacityIds;
        double opacity = _opacityValue;
        Apply(() => _edits.Opacity(page, ids, opacity), Loc.T("Opacity changed."));
    }

    private void FlushOpacity()
    {
        if (_opacityTimer.IsEnabled) OpacityTimer_Tick(null, EventArgs.Empty);
    }
}
