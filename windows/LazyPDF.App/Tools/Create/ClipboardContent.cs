using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;

namespace LazyPDF.App.Tools.Create;

public enum ClipboardKind
{
    Nothing,
    Text,
    Picture,
}

/// <summary>What the clipboard holds that a page can be made of: text, else a picture as PNG.</summary>
public sealed record ClipboardContent(string? Text, byte[]? Picture)
{
    /// <summary>What <see cref="Read"/> would find, without reading it: a screenshot is not encoded each time the panel looks.</summary>
    public static ClipboardKind Peek()
    {
        try
        {
            return Clipboard.ContainsText() ? ClipboardKind.Text : Clipboard.ContainsImage() ? ClipboardKind.Picture : ClipboardKind.Nothing;
        }
        catch (COMException)
        {
            // Another program has the clipboard open for a moment; it reads as empty.
            return ClipboardKind.Nothing;
        }
    }

    public static ClipboardContent Read()
    {
        try
        {
            if (Clipboard.ContainsText() && Clipboard.GetText() is { Length: > 0 } text) return new(text, null);
            if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image)
            {
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(image));
                using var stream = new MemoryStream();
                encoder.Save(stream);
                return new(null, stream.ToArray());
            }
        }
        catch (COMException)
        {
            // As above.
        }
        return new(null, null);
    }
}
