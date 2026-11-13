using System.Windows;
using System.Windows.Controls;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>Makes a text box that feeds text into the PDF flow right to left when the text starts with a right-to-left letter, as the saved page does.</summary>
public static class TextDirection
{
    public static readonly DependencyProperty FollowsProperty =
        DependencyProperty.RegisterAttached("Follows", typeof(bool), typeof(TextDirection), new PropertyMetadata(false, FollowsChanged));

    public static bool GetFollows(DependencyObject box) => (bool)box.GetValue(FollowsProperty);

    public static void SetFollows(DependencyObject box, bool value) => box.SetValue(FollowsProperty, value);

    // The first strong character sets the direction, so a long text only needs its start looked at.
    public static bool IsRightToLeft(string? text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        string start = text.Length > 256 ? text[..256] : text;
        return start.Any(c => c >= '\u0590') && new BidiParagraph(start).Level == 1;
    }

    public static FlowDirection Of(string? text) => IsRightToLeft(text) ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;

    private static void FollowsChanged(DependencyObject box, DependencyPropertyChangedEventArgs e)
    {
        if (box is not TextBox text) return;
        text.TextChanged -= Changed;
        if (e.NewValue is true)
        {
            text.TextChanged += Changed;
            text.FlowDirection = Of(text.Text);
        }
    }

    private static void Changed(object sender, TextChangedEventArgs e)
    {
        var box = (TextBox)sender;
        var flow = Of(box.Text);
        if (box.FlowDirection != flow) box.FlowDirection = flow;
    }
}
