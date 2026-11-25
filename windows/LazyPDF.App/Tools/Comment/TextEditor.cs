using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools.Comment;

/// <summary>A box on the page to type a note or a text box into. Ctrl+Enter or leaving it keeps the text, Escape drops it.</summary>
public sealed class TextEditor
{
    private readonly PageOverlay _overlay;
    private readonly TextBox _box;
    private readonly Action<string?> _done;
    private bool _closed;

    private TextEditor(PageOverlay overlay, Rect area, double fontSize, string text, int rotation, Action<string?> done)
    {
        _overlay = overlay;
        _done = done;
        double width = Math.Max(area.Width, 120);
        double line = fontSize * 1.4 + 6;
        double minHeight = Math.Max(Math.Max(area.Height, 40), line);
        // The overlay clips to the page, so keep the box inside it and let a long note scroll.
        double left = Math.Clamp(area.X, 0, Math.Max(0, overlay.Width - width));
        double top = Math.Clamp(area.Y, 0, Math.Max(0, overlay.Height - minHeight));
        _box = new TextBox
        {
            Text = text,
            Width = width,
            MinHeight = minHeight,
            MaxHeight = Math.Max(minHeight, overlay.Height - top),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontSize = fontSize,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Padding = new Thickness(2),
        };
        TextDirection.SetFollows(_box, true);
        AutomationProperties.SetName(_box, Loc.T("Text of the mark"));
        PageOverlay.KeepUpright(_box, rotation);
        Canvas.SetLeft(_box, left);
        Canvas.SetTop(_box, top);
        _box.PreviewKeyDown += Box_PreviewKeyDown;
        _box.LostKeyboardFocus += Box_LostKeyboardFocus;
        overlay.Children.Add(_box);
    }

    /// <summary>Opens the editor; <paramref name="done"/> gets the text, or null when it was dropped, and is called once.</summary>
    public static TextEditor Open(PageOverlay overlay, Rect area, double fontSize, string text, int rotation, Action<string?> done)
    {
        var editor = new TextEditor(overlay, area, fontSize, text, rotation, done);
        editor._box.Dispatcher.BeginInvoke(() =>
        {
            editor._box.Focus();
            Keyboard.Focus(editor._box);
            editor._box.SelectAll();
        }, System.Windows.Threading.DispatcherPriority.Input);
        return editor;
    }

    public void Upright(int rotation) => PageOverlay.KeepUpright(_box, rotation);

    /// <summary>Closes the box and hands over what was typed.</summary>
    public void Finish() => Close(_box.Text);

    /// <summary>Closes the box without keeping the text.</summary>
    public void Drop() => Close(null);

    private void Box_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Close(null);
            e.Handled = true;
        }
        else if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control)
        {
            Close(_box.Text);
            e.Handled = true;
        }
    }

    private void Box_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) => Close(_box.Text);

    private void Close(string? text)
    {
        if (_closed) return;
        _closed = true;
        _overlay.Children.Remove(_box);
        _done(text);
    }
}
