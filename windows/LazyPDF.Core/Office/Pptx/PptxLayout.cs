using System.Globalization;

namespace LazyPDF.Core.Office;

/// <summary>
/// Sets the slides of a presentation on pages the size of the slide: the background, the fill of every shape and its text, which
/// goes through <see cref="ParagraphLayout"/> and <see cref="Paginator.EmitLine"/> like Word text. There is no paginator; a
/// shape's text that does not fit runs over the edge of the shape, as it does in PowerPoint.
/// </summary>
internal static class PptxLayout
{
    private const double Wide = 1e7;
    private const int MaxBoxes = 4_000_000;

    /// <exception cref="PdfReadException">The slides come to too many boxes.</exception>
    public static LayoutResult Run(PptxPresentation presentation, LayoutFonts fonts, CancellationToken cancellation = default)
    {
        var pages = new List<LayoutPage>();
        int rightToLeft = 0, complex = 0, total = 0;
        foreach (var slide in presentation.Slides)
        {
            cancellation.ThrowIfCancellationRequested();
            var boxes = new List<LayoutBox>();
            if (slide.Background is { } background)
            {
                if (background.Color is { } color) boxes.Add(new PlacedRect(0, 0, presentation.Width, presentation.Height, color));
                if (background.Picture is { } picture) boxes.Add(new PlacedImage(0, 0, presentation.Width, presentation.Height, picture));
            }
            string number = slide.Number.ToString(CultureInfo.InvariantCulture);
            foreach (var shape in slide.Shapes)
            {
                if (shape.Fill is { } fill && shape.Width > 0 && shape.Height > 0) boxes.Add(new PlacedRect(shape.X, shape.Y, shape.Width, shape.Height, fill));
                if (shape.Body is { } body) Text(shape, body, fonts, number, boxes, ref rightToLeft, ref complex);
                if (total + boxes.Count > MaxBoxes) throw new PdfReadException(PdfReadProblem.Unsupported, "The presentation is too large.");
            }
            total += boxes.Count;
            pages.Add(new LayoutPage(presentation.Width, presentation.Height, boxes));
        }

        var skipped = presentation.Skipped.ToList();
        void Add(string kind, int count)
        {
            if (count <= 0) return;
            int at = skipped.FindIndex(s => s.Kind == kind);
            if (at < 0) skipped.Add(new SkippedFeature(kind, count));
            else skipped[at] = skipped[at] with { Count = skipped[at].Count + count };
        }
        Add(SkippedKinds.RightToLeftText, rightToLeft);
        Add(SkippedKinds.ComplexScript, complex);
        return new LayoutResult(pages, skipped, [.. fonts.Missing]);
    }

    private static void Text(PptxShape shape, PptxBody body, LayoutFonts fonts, string number, List<LayoutBox> boxes, ref int rightToLeft, ref int complex)
    {
        double inner = Math.Max(1, shape.Width - body.Left - body.Right);
        double room = shape.Height - body.Top - body.Bottom;
        var laid = new List<ParagraphLines>();
        foreach (var paragraph in body.Paragraphs)
        {
            var lines = ParagraphLayout.Run(body.Wrap ? paragraph : Unwrapped(paragraph), fonts, body.Wrap ? inner : Wide, Wide, _ => number);
            if (lines.RightToLeft) rightToLeft++;
            if (lines.ComplexScript) complex++;
            laid.Add(lines);
        }
        var aligns = body.Paragraphs.Select(p => p.Align).ToList();

        // PowerPoint ignores the space before the first paragraph and after the last one.
        double height = 0;
        for (int i = 0; i < laid.Count; i++)
        {
            height += laid[i].Height + (i > 0 ? laid[i].Source.Before : 0) + (i < laid.Count - 1 ? laid[i].Source.After : 0);
        }
        double y = shape.Y + body.Top + body.Anchor switch
        {
            LayoutVAlign.Center => (room - height) / 2,
            LayoutVAlign.Bottom => room - height,
            _ => 0,
        };
        double left = shape.X + body.Left;
        for (int i = 0; i < laid.Count; i++)
        {
            var lines = laid[i];
            if (i > 0) y += lines.Source.Before;
            foreach (var line in lines.Lines)
            {
                Paginator.EmitLine(boxes, line, left + (body.Wrap ? 0 : Shift(line, aligns[i], inner)), y);
                y += line.Height;
            }
            if (i < laid.Count - 1) y += lines.Source.After;
        }
    }

    // Text that does not wrap is laid out on a line without end and then moved so that its alignment holds against the shape.
    private static LayoutParagraph Unwrapped(LayoutParagraph p) => new()
    {
        Runs = p.Runs, Align = LayoutAlign.Left, Left = p.Left, Right = 0, FirstLine = p.FirstLine, Before = p.Before, After = p.After,
        LineSpacing = p.LineSpacing, Rule = p.Rule, LabelTab = p.LabelTab,
    };

    private static double Shift(LayoutLine line, LayoutAlign align, double inner)
    {
        int ink = line.Atoms.FindLastIndex(a => !a.IsBlank);
        if (ink < 0 || align is LayoutAlign.Left or LayoutAlign.Justify) return 0;
        double end = line.Atoms[ink].X + line.Atoms[ink].Width;
        return align == LayoutAlign.Center ? (inner - (end - line.Start)) / 2 - line.Start : inner - end;
    }
}
