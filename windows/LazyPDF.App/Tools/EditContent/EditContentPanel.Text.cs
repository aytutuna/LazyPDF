using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.Core;
using TextAlignment = LazyPDF.Core.TextAlignment;

namespace LazyPDF.App.Tools.EditContent;

// Text on the page: typing over a line, reflowing a paragraph, a new text box, and the look of both.
public sealed partial class EditContentPanel
{
    private enum Pending
    {
        None,
        Line,
        Paragraph,
        NewBox,
    }

    private Pending _pending;
    private int _pendingPage, _pendingId;
    private TextObjectLine? _pendingLine;
    private string _pendingOriginal = "";
    private PdfRect _pendingArea;
    private TextBoxStyle _newStyle = new("Arial");

    private EditorLook NewLook() => new(
        new System.Windows.Media.FontFamily(_newStyle.Family), _newStyle.Size, Palette.Brush(_newStyle.Color),
        _newStyle.Style.HasFlag(LazyPDF.Core.FontStyles.Bold), _newStyle.Style.HasFlag(LazyPDF.Core.FontStyles.Italic), _newStyle.Alignment);

    private void FillText(TextObject? text)
    {
        string family = text is null ? _newStyle.Family : EditorLook.NameOf(text.Font);
        FontBox.Text = family;
        SizeBox.Text = Number(text?.Size ?? _newStyle.Size);
        BoldButton.IsChecked = text is null ? _newStyle.Style.HasFlag(LazyPDF.Core.FontStyles.Bold) : text.Font?.IsBold;
        ItalicButton.IsChecked = text is null ? _newStyle.Style.HasFlag(LazyPDF.Core.FontStyles.Italic) : text.Font?.IsItalic;
        var alignment = text?.Alignment ?? _newStyle.Alignment ?? TextAlignment.Left;
        AlignLeft.IsChecked = alignment == TextAlignment.Left;
        AlignCenter.IsChecked = alignment == TextAlignment.Center;
        AlignRight.IsChecked = alignment == TextAlignment.Right;
        AlignJustify.IsChecked = alignment == TextAlignment.Justify;
        SpacingRow.Visibility = text is { Lines.Count: > 1 } ? Visibility.Visible : Visibility.Collapsed;
        if (text is not null) SpacingBox.Text = Number(text.LineSpacing);
        ParagraphButton.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
        ParagraphButton.IsEnabled = text is { IsTable: false };
        ParagraphReason.Visibility = text is { IsTable: true } ? Visibility.Visible : Visibility.Collapsed;
        ParagraphReason.Text = Loc.T("A table is changed one line at a time.");
    }

    // ----- The editor on the page

    private void Surface_TextClicked(int page, int id, Point at)
    {
        if (_edits!.Object(page, id) is not TextObject text || text.Lines.Count == 0) return;
        if (!Allowed(() => Surface_TextClicked(page, id, at))) return;
        var line = text.Lines.OrderBy(l => Distance(LineRect(page, l), at)).First();
        _pending = Pending.Line;
        (_pendingPage, _pendingId, _pendingLine) = (page, id, line);
        _editor!.Open(page, LineRect(page, line), line.Text, EditorLook.Of(text, _edits.Editor(page).Model.GlyphsIn(line.Range)), wrap: false, at);
        RaiseActionChanged();
    }

    private Rect LineRect(int page, TextObjectLine line)
    {
        var d = Viewer!.Geometry(page).ToDisplay(line.Bounds);
        return new Rect(d.X, d.Y, d.Width, d.Height);
    }

    private static double Distance(Rect r, Point p) => Math.Max(Math.Max(r.Left - p.X, p.X - r.Right), Math.Max(r.Top - p.Y, p.Y - r.Bottom));

    private void Paragraph_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedText() is not { } text) return;
        FinishPending();
        if (!Allowed(() => Paragraph_Click(sender, e))) return;
        var d = Viewer!.Geometry(_surface!.Page).ToDisplay(text.Bounds);
        _pending = Pending.Paragraph;
        (_pendingPage, _pendingId) = (_surface.Page, text.Id);
        _pendingOriginal = Regex.Replace(text.Text, @"\s*[\r\n]+\s*", " ");
        _editor!.Open(_pendingPage, new Rect(d.X, d.Y, d.Width, d.Height), _pendingOriginal, EditorLook.Of(text), wrap: true);
        RaiseActionChanged();
    }

    private void Surface_AreaDrawn(int page, PdfRect area)
    {
        switch (_surface!.Mode)
        {
            case EditMode.TextBox:
                if (!Allowed(() => Surface_AreaDrawn(page, area))) return;
                var d = Viewer!.Geometry(page).ToDisplay(area);
                _pending = Pending.NewBox;
                (_pendingPage, _pendingArea) = (page, area);
                _editor!.Open(page, new Rect(d.X, d.Y, d.Width, d.Height), "", NewLook(), wrap: true, lineBreaks: true);
                RaiseActionChanged();
                break;
            case EditMode.Link:
                StartLink(page, area, null);
                break;
            case EditMode.Crop:
                Crop(page, area);
                break;
        }
    }

    private void Editor_Committed(object? sender, EventArgs e) => CommitEditor();

    private void Editor_Cancelled(object? sender, EventArgs e) => CancelEditor();

    private Task ApplyTextAsync()
    {
        CommitEditor();
        return Task.CompletedTask;
    }

    // A press elsewhere on the page keeps what was typed; if Core refuses it the editor goes, and the reason stays shown.
    private void FinishPending()
    {
        if (_pending != Pending.None && !CommitEditor()) CancelEditor();
    }

    // True when the editor holds text that is not in the file yet.
    private bool HasTyped() => _editor is { IsOpen: true } editor && _pending switch
    {
        Pending.Line => editor.Text != _pendingLine!.Text,
        Pending.Paragraph => editor.Text != _pendingOriginal,
        Pending.NewBox => editor.Text.Trim().Length > 0,
        _ => false,
    };

    private void CancelEditor()
    {
        _editor?.Close();
        _pending = Pending.None;
        RaiseActionChanged();
    }

    private bool CommitEditor()
    {
        if (_pending == Pending.None || _editor is not { IsOpen: true } editor) return true;
        string text = editor.Text;
        int page = _pendingPage, id = _pendingId;
        var line = _pendingLine;
        bool done = _pending switch
        {
            Pending.Line => text == line!.Text || Apply(() => _edits!.ReplaceLine(page, line, text), Loc.T("Text changed.")),
            Pending.Paragraph => text == _pendingOriginal || Apply(() => _edits!.ReplaceParagraph(page, id, text), Loc.T("Paragraph changed.")),
            _ => text.Trim().Length == 0 || Apply(() => _edits!.AddTextBox(page, _pendingArea, text, _newStyle), Loc.T("Text box added.")),
        };
        if (done) CancelEditor();
        return done;
    }

    // ----- Look

    private void Restyle(TextStyleChange change, string status)
    {
        if (_loading || _surface is null) return;
        if (_surface.Mode == EditMode.Select)
        {
            EditSelectedText((page, id) => _edits!.Style(page, id, change), status);
            return;
        }
        var flags = _newStyle.Style;
        if (change.Bold is { } bold) flags = bold ? flags | LazyPDF.Core.FontStyles.Bold : flags & ~LazyPDF.Core.FontStyles.Bold;
        if (change.Italic is { } italic) flags = italic ? flags | LazyPDF.Core.FontStyles.Italic : flags & ~LazyPDF.Core.FontStyles.Italic;
        _newStyle = _newStyle with { Family = change.Family ?? _newStyle.Family, Size = change.Size ?? _newStyle.Size, Color = change.Color ?? _newStyle.Color, Style = flags };
        if (_pending == Pending.NewBox) _editor!.Restyle(NewLook());
    }

    // What is typed in the box is kept first, so that the change is made to the page as it will be and not as it was.
    private void EditSelectedText(Func<int, int, EditOutcome> edit, string status)
    {
        if (_pending is Pending.Line or Pending.Paragraph && !CommitEditor()) return;
        if (SelectedText() is not { } text) return;
        int page = _surface!.Page;
        Apply(() => edit(page, text.Id), status);
    }

    // Picking from the list changes the font; a name that is typed only does once Enter is pressed.
    private void FontBox_DropDownClosed(object? sender, EventArgs e)
    {
        if (_loading || FontBox.SelectedItem is not string family) return;
        if (family != (SelectedText() is { } text ? EditorLook.NameOf(text.Font) : _newStyle.Family)) Restyle(new TextStyleChange(Family: family), Loc.T("Font changed."));
    }

    private void FontBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || _loading || FontBox.Text.Trim().Length == 0) return;
        e.Handled = true;
        Restyle(new TextStyleChange(Family: FontBox.Text.Trim()), Loc.T("Font changed."));
    }

    private void Value_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        ((UIElement)sender).MoveFocus(new TraversalRequest(FocusNavigationDirection.Next));
    }

    private void SizeBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (_loading) return;
        double now = SelectedText()?.Size ?? _newStyle.Size;
        if (!TryNumber(SizeBox.Text, 1, 500, out double size)) SizeBox.Text = Number(now);
        else if (Math.Abs(size - now) > 0.05) Restyle(new TextStyleChange(Size: size), Loc.T("Size changed."));
    }

    private void SpacingBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (_loading || SelectedText() is not { } text) return;
        if (!TryNumber(SpacingBox.Text, 1, 500, out double spacing)) SpacingBox.Text = Number(text.LineSpacing);
        else if (Math.Abs(spacing - text.LineSpacing) > 0.05) EditSelectedText((page, id) => _edits!.Space(page, id, spacing), Loc.T("Spacing changed."));
    }

    private static bool TryNumber(string text, double min, double max, out double value) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out value) && value >= min && value <= max;

    private void Bold_Click(object sender, RoutedEventArgs e) =>
        Restyle(new TextStyleChange(Bold: BoldButton.IsChecked == true), Loc.T("Bold changed."));

    private void Italic_Click(object sender, RoutedEventArgs e) =>
        Restyle(new TextStyleChange(Italic: ItalicButton.IsChecked == true), Loc.T("Italic changed."));

    private void Align_Click(object sender, RoutedEventArgs e)
    {
        var alignment = sender == AlignCenter ? TextAlignment.Center : sender == AlignRight ? TextAlignment.Right : sender == AlignJustify ? TextAlignment.Justify : TextAlignment.Left;
        if (_surface!.Mode == EditMode.Select)
        {
            EditSelectedText((page, id) => _edits!.Align(page, id, alignment), Loc.T("Aligned."));
            return;
        }
        _newStyle = _newStyle with { Alignment = alignment };
        if (_pending == Pending.NewBox) _editor!.Restyle(NewLook());
    }
}
