using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LazyPDF.App.Services;
using LazyPDF.Core;
using FontStyles = LazyPDF.Core.FontStyles;
using TextBlock = System.Windows.Controls.TextBlock;

namespace LazyPDF.App.Tools.Stamps;

/// <summary>Draws a draft on a page's overlay, in page points, close to what Core will write.</summary>
public static partial class StampPreview
{
    // A background sits behind the text in the file; drawn in front it has to stay faint.
    private const double BackgroundCeiling = 0.25;

    /// <summary>The page's share of the draft, or null when the draft puts nothing on it.</summary>
    /// <param name="ordinal">How many stamped pages come before this one, which Bates numbers count.</param>
    public static UIElement? Build(StampDraft draft, ImageSource? picture, int page, int pageCount, int ordinal, Size size, string fileName, DateTimeOffset now)
    {
        var layer = new Canvas { Width = size.Width, Height = size.Height, IsHitTestVisible = false };
        if (draft.Watermark is { } mark) Watermark(layer, mark, picture, size);
        else if (draft.Background is { } back) Background(layer, back, picture, size);
        else HeaderFooter(layer, draft.HeaderFooter!, page, pageCount, ordinal, size, fileName, now);
        return layer.Children.Count == 0 ? null : layer;
    }

    /// <summary>Fills in <c>{page}</c>, <c>{pages}</c>, <c>{date}</c>, <c>{file}</c> and <c>{bates}</c>; anything else stays as typed.</summary>
    public static string Expand(string template, int page, int pages, string? bates, string fileName, DateTimeOffset date, string dateFormat) =>
        Token().Replace(template, m =>
        {
            string? argument = m.Groups[2].Success ? m.Groups[2].Value : null;
            switch (m.Groups[1].Value)
            {
                case "page": return page.ToString(CultureInfo.InvariantCulture);
                case "pages": return pages.ToString(CultureInfo.InvariantCulture);
                case "file": return fileName;
                case "bates": return bates ?? m.Value;
                case "date":
                    try { return date.ToString(string.IsNullOrEmpty(argument) ? dateFormat : argument, CultureInfo.CurrentCulture); }
                    catch (FormatException) { return m.Value; }
                default: return m.Value;
            }
        });

    [GeneratedRegex(@"\{(\w+)(?::([^}]*))?\}")]
    private static partial Regex Token();

    public static FontFamily Family(string name) => new(name switch
    {
        "Helvetica" => "Arial",
        "Times" => "Times New Roman",
        "Courier" => "Courier New",
        _ => name,
    });

    private static Brush Paint(StampColor color)
    {
        byte Channel(double level) => (byte)Math.Round(Math.Clamp(level, 0, 1) * 255);
        var brush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(Channel(color.R), Channel(color.G), Channel(color.B)));
        brush.Freeze();
        return brush;
    }

    private static TextBlock Text(string text, string family, FontStyles style, double size, StampColor color) => new()
    {
        Text = text,
        FontFamily = Family(family),
        FontSize = size,
        FontWeight = style.HasFlag(FontStyles.Bold) ? FontWeights.Bold : FontWeights.Normal,
        FontStyle = style.HasFlag(FontStyles.Italic) ? System.Windows.FontStyles.Italic : System.Windows.FontStyles.Normal,
        Foreground = Paint(color),
        TextAlignment = System.Windows.TextAlignment.Center,
        FlowDirection = TextDirection.Of(text),
    };

    private static Size Measured(UIElement element)
    {
        element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return element.DesiredSize;
    }

    private static void Watermark(Canvas layer, WatermarkSpec spec, ImageSource? picture, Size page)
    {
        double width = spec.Scale * page.Width;
        FrameworkElement element;
        if (spec.Text is { Length: > 0 } text && picture is null)
        {
            var lines = text.ReplaceLineEndings("\n").Split('\n');
            double widest = lines.Max(l => Measured(Text(l, spec.FontFamily, spec.FontStyle, 100, spec.Color)).Width);
            double size = widest > 0 ? Math.Clamp(width / widest * 100, 1, 1000) : 12;
            element = Text(string.Join("\n", lines), spec.FontFamily, spec.FontStyle, size, spec.Color);
        }
        else if (picture is not null && picture.Width > 0)
        {
            element = new System.Windows.Controls.Image { Source = picture, Width = width, Height = width * picture.Height / picture.Width, Stretch = Stretch.Fill };
        }
        else
        {
            return;
        }
        var box = Measured(element);
        int column = (int)spec.Anchor % 3, row = (int)spec.Anchor / 3;
        double x = column switch { 0 => 0, 1 => (page.Width - box.Width) / 2, _ => page.Width - box.Width };
        double y = row switch { 0 => 0, 1 => (page.Height - box.Height) / 2, _ => page.Height - box.Height };
        Canvas.SetLeft(element, x + spec.OffsetX);
        Canvas.SetTop(element, y + spec.OffsetY);
        element.Opacity = spec.Opacity;
        element.RenderTransform = new RotateTransform(-spec.Rotation, box.Width / 2, box.Height / 2);
        layer.Children.Add(element);
    }

    private static void Background(Canvas layer, BackgroundSpec spec, ImageSource? picture, Size page)
    {
        double opacity = Math.Min(spec.Opacity, BackgroundCeiling);
        if (spec.Color is { } color)
            layer.Children.Add(new System.Windows.Shapes.Rectangle { Width = page.Width, Height = page.Height, Fill = Paint(color), Opacity = opacity });
        if (picture is null || picture.Width <= 0 || picture.Height <= 0) return;
        var box = Fitted(spec.Fit, picture.Width, picture.Height, page);
        layer.Clip = new RectangleGeometry(new Rect(page));
        var image = new System.Windows.Controls.Image { Source = picture, Width = box.Width, Height = box.Height, Stretch = Stretch.Fill, Opacity = opacity };
        Canvas.SetLeft(image, box.X);
        Canvas.SetTop(image, box.Y);
        layer.Children.Add(image);
    }

    /// <summary>Where Core puts a background picture: scaled as the fit says and centred on the page.</summary>
    public static Rect Fitted(BackgroundFit fit, double width, double height, Size page)
    {
        double sx = page.Width / width, sy = page.Height / height;
        if (fit == BackgroundFit.Cover) sx = sy = Math.Max(sx, sy);
        else if (fit == BackgroundFit.Contain) sx = sy = Math.Min(sx, sy);
        double w = width * sx, h = height * sy;
        return new Rect((page.Width - w) / 2, (page.Height - h) / 2, w, h);
    }

    private static void HeaderFooter(Canvas layer, HeaderFooterSpec spec, int page, int pageCount, int ordinal, Size size, string fileName, DateTimeOffset now)
    {
        string? bates = spec.Bates?.Format(spec.Bates.Start + ordinal);
        int number = spec.StartNumber + page;
        int last = spec.StartNumber + pageCount - 1;
        string Slot(string template) => Expand(template, number, last, bates, fileName, now, spec.DateFormat);
        void Band(HeaderFooterBand band, bool header)
        {
            string[] texts = [Slot(band.Left), Slot(band.Center), Slot(band.Right)];
            for (int i = 0; i < 3; i++)
            {
                if (texts[i].Length == 0) continue;
                var text = Text(texts[i], spec.FontFamily, spec.FontStyle, spec.FontSize, spec.Color);
                text.TextWrapping = TextWrapping.NoWrap;
                var box = Measured(text);
                double x = i switch { 0 => spec.MarginX, 1 => (size.Width - box.Width) / 2, _ => size.Width - spec.MarginX - box.Width };
                Canvas.SetLeft(text, x);
                Canvas.SetTop(text, header ? spec.MarginTop : size.Height - spec.MarginBottom - box.Height);
                layer.Children.Add(text);
            }
        }
        Band(spec.Header, true);
        Band(spec.Footer, false);
    }
}
