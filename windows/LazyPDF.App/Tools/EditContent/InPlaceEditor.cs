using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.EditContent;

/// <summary>
/// A text box on the page over the text being changed, in the font and size of the run, so what is typed is what
/// the page will show. Enter keeps it, Escape drops it.
/// </summary>
internal sealed class InPlaceEditor(IDocumentViewer viewer)
{
    private TextBox? _box;
    private PageOverlay? _overlay;
    private bool _lineBreaks;
    private LazyPDF.Core.TextAlignment? _alignment;

    public bool IsOpen => _box is not null;

    public int Page { get; private set; }

    public string Text => _box?.Text ?? "";

    /// <summary>The person pressed Enter.</summary>
    public event EventHandler? Committed;

    /// <summary>The person pressed Escape.</summary>
    public event EventHandler? Cancelled;

    /// <param name="area">Where the text is, in page space.</param>
    /// <param name="caret">Where on the page the caret goes; the end of the text when null.</param>
    /// <param name="wrap">The text wraps inside the width of <paramref name="area"/> instead of growing to the right.</param>
    /// <param name="lineBreaks">Shift+Enter starts a new line; Enter still keeps the text.</param>
    public void Open(int page, Rect area, string text, EditorLook look, bool wrap, Point? caret = null, bool lineBreaks = false)
    {
        Close();
        _lineBreaks = lineBreaks;
        Page = page;
        double scale = ViewScale.Of(viewer, page);
        var box = new TextBox
        {
            Style = null,
            Text = text,
            BorderBrush = (Brush)Application.Current.FindResource("AccentFillColorDefaultBrush"),
            BorderThickness = new Thickness(1.5 / scale),
            Padding = new Thickness(0),
            MinWidth = area.Width,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            AcceptsReturn = lineBreaks,
            UndoLimit = 100,
        };
        var overlay = viewer.Overlay(page);
        box.MaxWidth = Math.Max(area.Width, overlay.Width - area.X);
        if (wrap)
        {
            box.Width = area.Width;
            box.MaxHeight = Math.Max(area.Height, overlay.Height - area.Y);
            box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        }
        System.Windows.Automation.AutomationProperties.SetName(box, Loc.T("Text on the page"));
        if (lineBreaks)
        {
            string hint = Loc.T("Enter keeps the text. Shift+Enter starts a new line.");
            box.ToolTip = hint;
            System.Windows.Automation.AutomationProperties.SetHelpText(box, hint);
        }
        Canvas.SetLeft(box, area.X);
        Canvas.SetTop(box, area.Y);
        Look(box, look);
        _alignment = look.Alignment;
        box.TextChanged += (_, _) => Flow(box);
        Flow(box);
        PageOverlay.KeepUpright(box, viewer.Rotation);
        box.PreviewKeyDown += Box_PreviewKeyDown;
        box.Loaded += (_, _) => box.Dispatcher.BeginInvoke(() =>
        {
            box.Focus();
            box.CaretIndex = caret is { } at ? box.GetCharacterIndexFromPoint(new Point(at.X - area.X, at.Y - area.Y), true) : box.Text.Length;
        });
        _box = box;
        _overlay = overlay;
        overlay.Children.Add(box);
    }

    /// <summary>Shows the text in another font, size or colour while it is open.</summary>
    public void Restyle(EditorLook look)
    {
        if (_box is null) return;
        Look(_box, look);
        _alignment = look.Alignment;
        Flow(_box);
    }

    public void Upright()
    {
        if (_box is not null) PageOverlay.KeepUpright(_box, viewer.Rotation);
    }

    public void Close()
    {
        if (_box is null) return;
        _overlay?.Children.Remove(_box);
        _box = null;
        _overlay = null;
        viewer.View.Focus();
    }

    private static void Look(TextBox box, EditorLook look)
    {
        bool light = look.Color.R * 0.3 + look.Color.G * 0.59 + look.Color.B * 0.11 > 190;
        box.FontFamily = look.Family;
        box.FontSize = look.Size;
        box.FontWeight = look.Bold ? FontWeights.Bold : FontWeights.Normal;
        box.FontStyle = look.Italic ? System.Windows.FontStyles.Italic : System.Windows.FontStyles.Normal;
        box.Foreground = new SolidColorBrush(look.Color);
        box.Background = light ? Brushes.Black : Brushes.White;
        box.CaretBrush = light ? Brushes.White : Brushes.Black;
    }

    // The box reads right to left when the text starts with a right-to-left letter, as the saved page will. A mirrored box
    // puts Left at the right edge, so the page's left and right swap; an alignment that is not set starts the line.
    private void Flow(TextBox box)
    {
        bool rtl = TextDirection.IsRightToLeft(box.Text);
        box.FlowDirection = rtl ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
        box.TextAlignment = _alignment switch
        {
            LazyPDF.Core.TextAlignment.Center => System.Windows.TextAlignment.Center,
            LazyPDF.Core.TextAlignment.Justify => System.Windows.TextAlignment.Justify,
            LazyPDF.Core.TextAlignment.Right => rtl ? System.Windows.TextAlignment.Left : System.Windows.TextAlignment.Right,
            LazyPDF.Core.TextAlignment.Left => rtl ? System.Windows.TextAlignment.Right : System.Windows.TextAlignment.Left,
            _ => System.Windows.TextAlignment.Left,
        };
    }

    private void Box_PreviewKeyDown(object sender, KeyEventArgs e) => PressKey(e, Keyboard.Modifiers);

    internal void PressKey(KeyEventArgs e, ModifierKeys modifiers)
    {
        if (e.Key == Key.Enter && _lineBreaks && (modifiers & ModifierKeys.Shift) != 0)
        {
            // Plain Shift+Enter is the TextBox's own line break; Ctrl+Shift+Enter would reach the viewer, so insert it here
            if ((modifiers & ModifierKeys.Control) != 0 && _box is { } box)
            {
                e.Handled = true;
                box.SelectedText = Environment.NewLine;
                box.CaretIndex += Environment.NewLine.Length;
                box.SelectionLength = 0;
            }
        }
        else if (e.Key == Key.Enter)
        {
            e.Handled = true;
            Committed?.Invoke(this, EventArgs.Empty);
        }
        else if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Cancelled?.Invoke(this, EventArgs.Empty);
        }
    }
}
