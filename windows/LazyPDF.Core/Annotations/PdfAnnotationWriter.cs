namespace LazyPDF.Core;

/// <summary>
/// Creates annotations on a page and changes them. Every annotation made or changed gets an /AP /N
/// that carries all of its look, because the system renderer ignores /CA and /NeedAppearances. The
/// document is edited in memory; the edit session commits it. Each call returns the annotation as it
/// stands, and the values of the one passed in are stale afterwards.
/// </summary>
/// <param name="fonts">Where fonts for text that Standard 14 cannot draw (Turkish ğ, ş, ı) come from.</param>
public sealed partial class PdfAnnotationWriter(PdfDocument document, IFontSource? fonts = null)
{
    private readonly AppearanceBuilder _appearance = new(document, fonts);

    /// <summary>
    /// The characters that no installed font could draw in the free text, stamps and redraws since the last
    /// call, once each in code point order; they are left blank. Clears them.
    /// </summary>
    public string TakeUndrawn() => _appearance.TakeUndrawn();

    private PdfDictionary NewAnnotation(string subtype, PdfRect rect, AnnotationInfo? info, double[]? color, double opacity = 1)
    {
        var d = new PdfDictionary
        {
            ["Type"] = new PdfName("Annot"),
            ["Subtype"] = new PdfName(subtype),
            ["Rect"] = rect.ToArray(),
            ["F"] = new PdfNumber((long)(info?.Flags ?? AnnotationFlags.Print)),
            ["NM"] = PdfText.ToObject(Guid.NewGuid().ToString()),
        };
        if (color is not null) d["C"] = Numbers(color);
        if (opacity < 1) d["CA"] = new PdfNumber(Math.Clamp(opacity, 0, 1));
        if (info?.Author is { Length: > 0 } author) d["T"] = PdfText.ToObject(author);
        if (info?.Contents is { Length: > 0 } contents) d["Contents"] = PdfText.ToObject(contents);
        if (info?.Subject is { Length: > 0 } subject) d["Subj"] = PdfText.ToObject(subject);
        if (info?.Date is { } date)
        {
            d["CreationDate"] = PdfText.ToObject(PdfDate.Format(date));
            d["M"] = PdfText.ToObject(PdfDate.Format(date));
        }
        return d;
    }

    private static void SetBorder(PdfDictionary d, AnnotationStyle style)
    {
        var bs = new PdfDictionary { ["Type"] = new PdfName("Border"), ["W"] = new PdfNumber(style.Width) };
        if (style.Dash is { Length: > 0 } dash)
        {
            bs["S"] = new PdfName("D");
            bs["D"] = Numbers(dash);
        }
        else bs["S"] = new PdfName("S");
        d["BS"] = bs;
    }

    private static PdfArray Numbers(IEnumerable<double> values) => new([.. values.Select(v => (PdfObject)new PdfNumber(v))]);

    /// <summary>Draws the appearance, adds the annotation to the page and reads it back.</summary>
    private PdfAnnotation Place(PdfPage page, PdfDictionary d)
    {
        if (!_appearance.Apply(d)) throw new ArgumentException("The annotation has no area to draw.");
        return Attach(page, d);
    }

    private PdfAnnotation Attach(PdfPage page, PdfDictionary d)
    {
        var reference = document.Add(d);
        if (document.Array(page.Dictionary, "Annots") is { } annots) annots.Items.Add(reference);
        else page.Dictionary["Annots"] = new PdfArray([reference]);
        return PdfAnnotations.Parse(document, d, reference, page.Index)!;
    }

    private static PdfRect Inflate(PdfRect r, double by) => new(r.Left - by, r.Bottom - by, r.Right + by, r.Top + by);

    private static PdfRect BoundsOf(IEnumerable<(double X, double Y)> points)
    {
        var list = points.ToList();
        if (list.Count == 0) throw new ArgumentException("There are no points.");
        return new PdfRect(list.Min(p => p.X), list.Min(p => p.Y), list.Max(p => p.X), list.Max(p => p.Y));
    }

    /// <summary>The appearance drawn again from the annotation's keys, replacing the one it had; false for a kind this layer does not draw.</summary>
    public bool Regenerate(PdfAnnotation annotation) => _appearance.Apply(annotation.Dictionary);

    /// <summary>Shifts the annotation and the points it keeps; the appearance moves with /Rect.</summary>
    public PdfAnnotation Move(PdfAnnotation annotation, double dx, double dy) => Edit(annotation, redraw: false, () =>
    {
        Map(annotation.Dictionary, x => x + dx, y => y + dy);
        annotation.Dictionary["Rect"] = new PdfRect(annotation.Rect.Left + dx, annotation.Rect.Bottom + dy, annotation.Rect.Right + dx, annotation.Rect.Top + dy).ToArray();
    });

    /// <summary>
    /// Fits the annotation and its points into <paramref name="rect"/>, then draws it again so that
    /// borders keep their width and text wraps anew. An image stamp or a stamp from another writer is left to scale.
    /// </summary>
    public PdfAnnotation Resize(PdfAnnotation annotation, PdfRect rect) => Edit(annotation, redraw: true, () =>
    {
        var old = annotation.Rect;
        double sx = old.Width > 0 ? rect.Width / old.Width : 1, sy = old.Height > 0 ? rect.Height / old.Height : 1;
        Map(annotation.Dictionary, x => rect.Left + (x - old.Left) * sx, y => rect.Bottom + (y - old.Bottom) * sy);
        annotation.Dictionary["Rect"] = rect.ToArray();
    });

    /// <summary>Sets the main colour (/C) and, when given, the interior colour (/IC); an empty array makes it transparent.</summary>
    public PdfAnnotation SetColor(PdfAnnotation annotation, double[] color, double[]? interior = null) => Edit(annotation, redraw: true, () =>
    {
        annotation.Dictionary["C"] = Numbers(color);
        if (interior is not null) annotation.Dictionary["IC"] = Numbers(interior);
    });

    public PdfAnnotation SetOpacity(PdfAnnotation annotation, double opacity) => Edit(annotation, redraw: true, () =>
        annotation.Dictionary["CA"] = new PdfNumber(Math.Clamp(opacity, 0, 1)));

    /// <summary>Changes /Contents and /M. A free text box is drawn again with the new text, its rich text dropped as out of date.</summary>
    public PdfAnnotation SetContents(PdfAnnotation annotation, string text, DateTimeOffset? date = null) =>
        Edit(annotation, redraw: annotation.Type == AnnotationType.FreeText, () =>
        {
            var d = annotation.Dictionary;
            d["Contents"] = PdfText.ToObject(text);
            if (date is { } modified) d["M"] = PdfText.ToObject(PdfDate.Format(modified));
            if (annotation.Type == AnnotationType.FreeText) d.Remove("RC");
        });

    // Runs a change and, when it asks for it, draws the appearance again. A drawing that fails (no font
    // for the text) leaves the annotation as it was.
    private PdfAnnotation Edit(PdfAnnotation annotation, bool redraw, Action change)
    {
        var d = annotation.Dictionary;
        var before = d.Copy();
        try
        {
            change();
            if (redraw) Regenerate(annotation);
        }
        catch
        {
            foreach (var key in d.Entries.Select(e => e.Key).Distinct().ToList()) d.Remove(key);
            foreach (var (key, value) in before.Entries) d[key] = value;
            throw;
        }
        return Reread(annotation);
    }

    /// <summary>
    /// Removes the annotation from its page and frees it, with its popup and every reply that leads
    /// back to it. False when the page no longer lists it.
    /// </summary>
    public bool Delete(PdfAnnotation annotation)
    {
        if (annotation.PageIndex < 0 || annotation.PageIndex >= document.Pages.Count) return false;
        var page = document.Pages[annotation.PageIndex];
        if (document.Array(page.Dictionary, "Annots") is not { } annots) return false;
        if (!annots.Items.Any(i => IsSame(i, annotation))) return false;

        var doomed = new List<PdfAnnotation> { annotation };
        var onPage = PdfAnnotations.Read(document, page);
        for (int i = 0; i < doomed.Count; i++)
        {
            if (doomed[i].Reference is not { } parent) continue;
            foreach (var other in onPage)
            {
                if (other.InReplyTo?.Number == parent.Number && !doomed.Any(x => ReferenceEquals(x.Dictionary, other.Dictionary))) doomed.Add(other);
            }
        }
        foreach (var gone in doomed)
        {
            Unlink(gone);
            if (gone.Popup is { } popup) Remove(annots, document.Resolve(popup), popup);
            Remove(annots, gone.Dictionary, gone.Reference);
        }
        return true;
    }

    // A widget also sits in its field's /Kids or the form's /Fields, a popup is named by its owner.
    private void Unlink(PdfAnnotation gone)
    {
        var d = gone.Dictionary;
        bool Is(PdfObject i) => ReferenceEquals(document.Resolve(i), d) || (gone.Reference is { } r && i is PdfReference x && x.Number == r.Number);
        if (gone.Type == AnnotationType.Widget)
        {
            var holder = document.Array(document.Dict(d, "Parent"), "Kids") ?? document.Array(document.Dict(document.Catalog, "AcroForm"), "Fields");
            holder?.Items.RemoveAll(Is);
        }
        else if (gone.Type == AnnotationType.Popup && document.Dict(d, "Parent") is { } owner && Is(owner["Popup"] ?? PdfNull.Instance))
        {
            owner.Remove("Popup");
        }
    }

    private void Remove(PdfArray annots, PdfObject? target, PdfReference? reference)
    {
        annots.Items.RemoveAll(i => ReferenceEquals(document.Resolve(i), target));
        if (reference is not null) document.Delete(reference.Number);
    }

    private bool IsSame(PdfObject item, PdfAnnotation annotation) => ReferenceEquals(document.Resolve(item), annotation.Dictionary);

    private PdfAnnotation Reread(PdfAnnotation old) => PdfAnnotations.Parse(document, old.Dictionary, old.Reference, old.PageIndex)!;

    // Applies a point mapping to every key that holds page coordinates. The arrays are replaced, not
    // changed in place, so that Edit can put the old ones back.
    private void Map(PdfDictionary d, Func<double, double> fx, Func<double, double> fy)
    {
        foreach (string key in (ReadOnlySpan<string>)["QuadPoints", "Vertices", "L", "CL"])
        {
            if (document.Array(d, key) is { } array) d[key] = MapPairs(array, fx, fy);
        }
        if (document.Array(d, "InkList") is { } ink)
        {
            d["InkList"] = new PdfArray([.. ink.Items.Select(path => document.Resolve(path) is PdfArray inner ? MapPairs(inner, fx, fy) : path)]);
        }
    }

    private PdfArray MapPairs(PdfArray array, Func<double, double> fx, Func<double, double> fy)
    {
        var items = new List<PdfObject>(array.Items);
        for (int i = 0; i + 1 < items.Count; i += 2)
        {
            if (document.Resolve(items[i]) is PdfNumber x && document.Resolve(items[i + 1]) is PdfNumber y)
            {
                items[i] = new PdfNumber(fx(x.Value));
                items[i + 1] = new PdfNumber(fy(y.Value));
            }
        }
        return new PdfArray(items);
    }
}
