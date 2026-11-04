namespace LazyPDF.Core;

/// <summary>
/// Burns annotation appearances into the page content (ISO 32000-1 12.5.5) and takes the annotations
/// out of the page. Hidden annotations and those marked NoView have no appearance on screen and are
/// left alone, as are annotations without an appearance stream.
/// </summary>
public static class PdfAnnotationFlattener
{
    /// <summary>
    /// What "all" means: every kind that only shows something. Links, form widgets, popups, attachments
    /// and redaction marks do more than that and have to be named to be flattened.
    /// </summary>
    public static IReadOnlySet<AnnotationType> DefaultTypes { get; } = new HashSet<AnnotationType>
    {
        AnnotationType.Text, AnnotationType.FreeText, AnnotationType.Line, AnnotationType.Square, AnnotationType.Circle,
        AnnotationType.Polygon, AnnotationType.PolyLine, AnnotationType.Highlight, AnnotationType.Underline, AnnotationType.Squiggly,
        AnnotationType.StrikeOut, AnnotationType.Stamp, AnnotationType.Caret, AnnotationType.Ink, AnnotationType.Other,
    };

    /// <summary>Flattens the annotations of every page; the number of annotations burned in.</summary>
    public static int FlattenAll(PdfDocument document, IReadOnlySet<AnnotationType>? types = null) =>
        document.Pages.Sum(page => Flatten(document, page, types));

    /// <summary>
    /// Flattens the page's annotations of <paramref name="types"/> (null: <see cref="DefaultTypes"/>) and
    /// returns how many were burned in. Their popups and replies go with them.
    /// </summary>
    public static int Flatten(PdfDocument document, PdfPage page, IReadOnlySet<AnnotationType>? types = null)
    {
        types ??= DefaultTypes;
        return Flatten(document, page, a => types.Contains(a.Type));
    }

    /// <summary>The same for the annotations <paramref name="include"/> picks; the Forms layer flattens chosen widgets with it.</summary>
    internal static int Flatten(PdfDocument document, PdfPage page, Func<PdfAnnotation, bool> include)
    {
        var all = PdfAnnotations.Read(document, page);
        var drawn = new List<(PdfAnnotation Annotation, PdfReference Form, PdfStream Stream)>();
        var off = PdfLayers.Read(document).Layers.Where(l => !l.IsOn).Select(l => l.Reference.Number).ToHashSet();
        foreach (var a in all)
        {
            if (!include(a) || a.Flags.HasFlag(AnnotationFlags.Hidden) || a.Flags.HasFlag(AnnotationFlags.NoView)) continue;
            // What a hidden layer holds is not on show, so it is not burned in.
            if (a.Dictionary["OC"] is PdfReference group && off.Contains(group.Number)) continue;
            if (Appearance(document, a.Dictionary) is { } form) drawn.Add((a, form.Reference, form.Stream));
        }
        if (drawn.Count == 0) return 0;

        var resources = ContentResources.ForEdit(document, page);
        var content = new ContentWriter();
        foreach (var (annotation, reference, stream) in drawn)
        {
            if (!stream.Dictionary.ContainsKey("Subtype")) stream.Dictionary["Subtype"] = new PdfName("Form");
            string name = ContentResources.Add(document, resources, "XObject", reference, "Fm");
            bool upright = annotation.Flags.HasFlag(AnnotationFlags.NoRotate) && page.Rotate != 0;
            content.Paint(name, upright ? Upright(document, stream, annotation.Rect, page) : Placement(document, stream, annotation.Rect));
        }
        Surround(document, page, content.ToArray());

        var gone = new HashSet<PdfDictionary>(drawn.Select(d => d.Annotation.Dictionary));
        var numbers = new HashSet<int>(drawn.Select(d => d.Annotation.Reference?.Number).OfType<int>());
        // Popups and replies of a flattened annotation, replies of replies included.
        for (bool grew = true; grew;)
        {
            grew = false;
            foreach (var a in all)
            {
                bool child = a.Type == AnnotationType.Popup && a.Dictionary["Parent"] is PdfReference p && numbers.Contains(p.Number)
                    || a.InReplyTo is { } r && numbers.Contains(r.Number);
                if (child && gone.Add(a.Dictionary))
                {
                    grew = true;
                    if (a.Reference is { } reference) numbers.Add(reference.Number);
                }
            }
        }
        if (document.Array(page.Dictionary, "Annots") is { } annots)
        {
            annots.Items.RemoveAll(i => document.Resolve(i) is PdfDictionary d && gone.Contains(d));
        }
        foreach (int number in numbers) document.Delete(number);
        return drawn.Count;
    }

    private static (PdfReference Reference, PdfStream Stream)? Appearance(PdfDocument document, PdfDictionary annotation)
    {
        if (document.Dict(annotation, "AP") is not { } ap || ap["N"] is not { } normal) return null;
        var value = normal;
        if (document.Resolve(normal) is PdfDictionary states)
        {
            string? state = document.Name(annotation, "AS");
            if (state is null || states[state] is not { } chosen) return null;
            value = chosen;
        }
        if (document.Resolve(value) is not PdfStream stream) return null;
        var reference = value as PdfReference ?? (stream.Number > 0 ? new PdfReference(stream.Number, stream.Generation) : null);
        return reference is null ? null : (reference, stream);
    }

    // The algorithm of 12.5.5: the form's box through its matrix, then fitted to /Rect.
    private static PdfMatrix Placement(PdfDocument document, PdfStream form, PdfRect rect)
    {
        var box = document.Rect(form.Dictionary, "BBox") ?? new PdfRect(0, 0, rect.Width, rect.Height);
        var matrix = PdfMatrix.FromArray(document.Array(form.Dictionary, "Matrix"), document.Resolve) ?? PdfMatrix.Identity;
        var transformed = matrix.Transform(box);
        double sx = transformed.Width > 0 ? rect.Width / transformed.Width : 1, sy = transformed.Height > 0 ? rect.Height / transformed.Height : 1;
        return new PdfMatrix(sx, 0, 0, sy, rect.Left - transformed.Left * sx, rect.Bottom - transformed.Bottom * sy);
    }

    // NoRotate (12.5.3): the appearance stays upright on the shown page, at its natural size, with the
    // corner of the rectangle that is shown top left kept where it is.
    private static PdfMatrix Upright(PdfDocument document, PdfStream form, PdfRect rect, PdfPage page)
    {
        var box = document.Rect(form.Dictionary, "BBox") ?? new PdfRect(0, 0, rect.Width, rect.Height);
        var matrix = PdfMatrix.FromArray(document.Array(form.Dictionary, "Matrix"), document.Resolve) ?? PdfMatrix.Identity;
        var natural = matrix.Transform(box);
        var geometry = new PageGeometry(page);
        var anchor = geometry.ToDisplay(rect);
        double unit = page.UserUnit;
        (double X, double Y) At(double u, double v) =>
            geometry.ToUser(anchor.X + (u - natural.Left) * unit, anchor.Y + (natural.Top - v) * unit);
        var origin = At(natural.Left, natural.Bottom);
        var right = At(natural.Left + 1, natural.Bottom);
        var up = At(natural.Left, natural.Bottom + 1);
        double a = right.X - origin.X, b = right.Y - origin.Y, c = up.X - origin.X, d = up.Y - origin.Y;
        return new PdfMatrix(a, b, c, d, origin.X - a * natural.Left - c * natural.Bottom, origin.Y - b * natural.Left - d * natural.Bottom);
    }

    // Wraps the page's own content in q ... Q, closing any q it left open, so that nothing it left in
    // the graphics state reaches the annotations.
    private static void Surround(PdfDocument document, PdfPage page, byte[] annotations)
    {
        int open = 0;
        foreach (var operation in ContentParser.Parse(page.Contents()))
        {
            if (operation.Operator == "q") open++;
            else if (operation.Operator == "Q" && open > 0) open--;
        }
        byte[] closing = System.Text.Encoding.ASCII.GetBytes(string.Concat(Enumerable.Repeat("Q\n", Math.Min(open, 256))));
        var head = document.Add(new PdfStream(new PdfDictionary(), "q\n"u8.ToArray()));
        var tail = document.Add(new PdfStream(new PdfDictionary(), [.. closing, .. "Q\n"u8, .. annotations]));
        var items = new List<PdfObject> { head };
        var existing = page.Dictionary["Contents"];
        if (document.Resolve(existing) is PdfArray array) items.AddRange(array.Items);
        else if (existing is not null && document.Resolve(existing) is PdfStream) items.Add(existing);
        items.Add(tail);
        page.Dictionary["Contents"] = new PdfArray(items);
    }
}
