using System.Security.Cryptography;

namespace LazyPDF.Core;

public sealed partial class PdfAnnotationWriter
{
    private static readonly double[] NoteYellow = [1, 0.9, 0.2];

    /// <summary>A sticky note. <paramref name="rect"/> is the icon, 20 by 20 points as a rule; <paramref name="icon"/> is /Name (Note, Comment, Key, Help, Paragraph...).</summary>
    public PdfAnnotation AddNote(PdfPage page, PdfRect rect, AnnotationInfo info, string icon = "Note", double[]? color = null)
    {
        var withFlags = info with { Flags = info.Flags | AnnotationFlags.NoZoom | AnnotationFlags.NoRotate };
        var d = NewAnnotation("Text", rect, withFlags, color ?? NoteYellow);
        d["Name"] = new PdfName(icon);
        d["Open"] = new PdfBoolean(false);
        return Place(page, d);
    }

    // A reply is a note nobody should see on the page: hidden, kept in the list by /IRT.
    internal PdfAnnotation AddReply(PdfAnnotation parent, AnnotationInfo info, ReviewStatus? status)
    {
        if (parent.Reference is not { } target || parent.PageIndex < 0 || parent.PageIndex >= document.Pages.Count)
            throw new ArgumentException("The annotation to answer is not an indirect object on a page.", nameof(parent));
        var rect = new PdfRect(parent.Rect.Left, parent.Rect.Top - 20, parent.Rect.Left + 20, parent.Rect.Top);
        var flags = info with { Flags = AnnotationFlags.Hidden | AnnotationFlags.Print | AnnotationFlags.NoZoom | AnnotationFlags.NoRotate };
        var d = NewAnnotation("Text", rect, flags, NoteYellow);
        d["IRT"] = target;
        d["RT"] = new PdfName("R");
        d["Name"] = new PdfName("Note");
        if (status is { } s)
        {
            d["StateModel"] = PdfText.ToObject(s is ReviewStatus.Marked or ReviewStatus.Unmarked ? "Marked" : "Review");
            d["State"] = PdfText.ToObject(s.ToString());
        }
        return Place(document.Pages[parent.PageIndex], d);
    }

    /// <summary>
    /// A text box. With <paramref name="callout"/> (two or three points, the first at what it points
    /// to) the annotation grows to hold the callout line and /RD marks where the box sits in it.
    /// </summary>
    public PdfAnnotation AddFreeText(PdfPage page, PdfRect box, string text, FreeTextStyle? font = null, AnnotationStyle? style = null,
        AnnotationInfo? info = null, IReadOnlyList<(double X, double Y)>? callout = null)
    {
        font ??= new FreeTextStyle();
        style ??= new AnnotationStyle(Width: 0);
        if (callout is not null && callout.Count is < 2 or > 3) throw new ArgumentException("A callout has two or three points.", nameof(callout));
        string plain = text.Length == 0 && font.RichText is not null ? PdfRichText.ToPlain(font.RichText) : text;
        var contents = (info ?? new AnnotationInfo()) with { Contents = plain };

        var rect = box;
        if (callout is not null)
        {
            double margin = AppearanceBuilder.EndingSize(Math.Max(1, style.Width)) + Math.Max(1, style.Width);
            var bounds = BoundsOf(callout);
            rect = new PdfRect(Math.Min(box.Left, bounds.Left - margin), Math.Min(box.Bottom, bounds.Bottom - margin),
                Math.Max(box.Right, bounds.Right + margin), Math.Max(box.Top, bounds.Top + margin));
        }
        var d = NewAnnotation("FreeText", rect, contents, style.Color, style.Opacity);
        if (style.Fill is not null) d["IC"] = Numbers(style.Fill);
        SetBorder(d, style);
        if (callout is not null)
        {
            d["IT"] = new PdfName("FreeTextCallout");
            d["CL"] = Numbers(callout.SelectMany(p => new[] { p.X, p.Y }));
            d["LE"] = new PdfName("OpenArrow");
        }
        else d["IT"] = new PdfName("FreeText");
        if (rect != box) d["RD"] = Numbers([box.Left - rect.Left, box.Bottom - rect.Bottom, rect.Right - box.Right, rect.Top - box.Top]);
        SetTextKeys(d, font);
        return Place(page, d);
    }

    /// <summary>Changes the font, size, colour, alignment or rich text of a free text annotation and draws it again.</summary>
    public PdfAnnotation SetFreeTextStyle(PdfAnnotation annotation, FreeTextStyle font)
    {
        if (annotation.Type != AnnotationType.FreeText) throw new ArgumentException("Not a free text annotation.", nameof(annotation));
        return Edit(annotation, redraw: true, () => SetTextKeys(annotation.Dictionary, font));
    }

    private static void SetTextKeys(PdfDictionary d, FreeTextStyle font)
    {
        var format = new TextFormat(font.Family, font.Size, font.Font.HasFlag(FontStyles.Bold), font.Font.HasFlag(FontStyles.Italic), false, font.TextColor ?? [0]);
        d["DA"] = PdfText.ToObject(DefaultAppearance.Build(format));
        d["DS"] = PdfText.ToObject(DefaultAppearance.BuildStyle(format, font.Alignment));
        d["Q"] = new PdfNumber(Math.Clamp(font.Alignment, 0, 2));
        if (font.RichText is { Length: > 0 } rich) d["RC"] = PdfText.ToObject(rich);
        else d.Remove("RC");
    }

    /// <summary>A stamp drawn as bold text in a box. <paramref name="name"/> is a standard name (<see cref="AnnotationText.StandardStamps"/>) or the words to show.</summary>
    public PdfAnnotation AddStamp(PdfPage page, PdfRect rect, string name, AnnotationInfo? info = null, double[]? color = null)
    {
        var d = NewAnnotation("Stamp", rect, info, color);
        d["Name"] = PdfName.FromText(name);
        return Place(page, d);
    }

    /// <summary>A stamp showing straight RGBA8 pixels, top row first.</summary>
    public PdfAnnotation AddImageStamp(PdfPage page, PdfRect rect, int width, int height, byte[] rgba, AnnotationInfo? info = null) =>
        PlaceImage(page, rect, ContentImages.AddRgba(document, width, height, rgba), info);

    /// <summary>A stamp showing a JPEG file as it is.</summary>
    public PdfAnnotation AddJpegStamp(PdfPage page, PdfRect rect, byte[] jpeg, AnnotationInfo? info = null) =>
        PlaceImage(page, rect, ContentImages.AddJpeg(document, jpeg) ?? throw new ArgumentException("The JPEG cannot be read.", nameof(jpeg)), info);

    private PdfAnnotation PlaceImage(PdfPage page, PdfRect rect, PdfReference image, AnnotationInfo? info)
    {
        if (rect.IsEmpty) throw new ArgumentException("The stamp has no area.", nameof(rect));
        var d = NewAnnotation("Stamp", rect, info, null);
        d["Name"] = new PdfName("Image");
        var canvas = new AppearanceCanvas(document, rect);
        string name = canvas.AddXObject(image);
        canvas.W.Paint(name, new PdfMatrix(rect.Width, 0, 0, rect.Height, 0, 0));
        d["AP"] = new PdfDictionary { ["N"] = document.Add(canvas.ToStream()) };
        return Attach(page, d);
    }

    /// <summary>The proofreader's caret for inserted text (/Sy /P).</summary>
    public PdfAnnotation AddCaret(PdfPage page, PdfRect rect, AnnotationInfo? info = null, AnnotationStyle? style = null)
    {
        style ??= new AnnotationStyle();
        var d = NewAnnotation("Caret", rect, info, style.Color ?? AppearanceBuilder.Black, style.Opacity);
        d["Sy"] = new PdfName("P");
        return Place(page, d);
    }

    /// <summary>A file attached at a point. <paramref name="icon"/> is PushPin, Paperclip, Graph or Tag.</summary>
    public PdfAnnotation AddFileAttachment(PdfPage page, PdfRect rect, string fileName, byte[] data, AnnotationInfo? info = null, string icon = "PushPin", string? mimeType = null)
    {
        var parameters = new PdfDictionary { ["Size"] = new PdfNumber(data.Length), ["CheckSum"] = new PdfString(MD5.HashData(data), true) };
        if (info?.Date is { } date) parameters["ModDate"] = PdfText.ToObject(PdfDate.Format(date));
        var file = new PdfDictionary { ["Type"] = new PdfName("EmbeddedFile"), ["Params"] = parameters };
        if (mimeType is not null) file["Subtype"] = new PdfName(mimeType);
        byte[] stored = data;
        if (data.Length > 64 && PdfFilterEncoders.Flate(data) is { } packed && packed.Length < data.Length)
        {
            stored = packed;
            file["Filter"] = new PdfName("FlateDecode");
        }
        var stream = document.Add(new PdfStream(file, stored));
        var spec = new PdfDictionary
        {
            ["Type"] = new PdfName("Filespec"),
            ["F"] = PdfText.ToFileName(fileName),
            ["UF"] = PdfText.ToObject(fileName),
            ["EF"] = new PdfDictionary { ["F"] = stream, ["UF"] = stream },
        };
        var withFlags = (info ?? new AnnotationInfo()) with { Flags = (info?.Flags ?? AnnotationFlags.Print) | AnnotationFlags.NoZoom | AnnotationFlags.NoRotate };
        var d = NewAnnotation("FileAttachment", rect, withFlags, null);
        d["Name"] = new PdfName(icon);
        d["FS"] = document.Add(spec);
        return Place(page, d);
    }

    /// <summary>
    /// The mark for a redaction over the quads (ISO 32000-2 12.5.6.23); the content under it stays until a later
    /// step removes it. <paramref name="fill"/> is the colour the area gets then and <paramref name="overlayText"/> the text drawn on it.
    /// </summary>
    public PdfAnnotation AddRedact(PdfPage page, IReadOnlyList<MarkupQuad> quads, AnnotationInfo? info = null, double[]? fill = null, string? overlayText = null)
    {
        if (quads.Count == 0) throw new ArgumentException("A redaction needs at least one quad.", nameof(quads));
        var bounds = quads.Select(q => q.Bounds).Aggregate((a, b) => new PdfRect(Math.Min(a.Left, b.Left), Math.Min(a.Bottom, b.Bottom), Math.Max(a.Right, b.Right), Math.Max(a.Top, b.Top)));
        var d = NewAnnotation("Redact", Inflate(bounds, 2), info, AppearanceBuilder.Red);
        d["QuadPoints"] = Numbers(quads.SelectMany(q => q.ToNumbers()));
        d["IC"] = Numbers(fill ?? AppearanceBuilder.Black);
        if (overlayText is { Length: > 0 }) d["OverlayText"] = PdfText.ToObject(overlayText);
        return Place(page, d);
    }

    /// <summary>A link to a place in the document. With a border in <paramref name="style"/> (width above 0 and a colour) the link gets an appearance that draws it.</summary>
    public PdfAnnotation AddLink(PdfPage page, PdfRect rect, PdfDestination destination, AnnotationStyle? style = null) =>
        PlaceLink(page, rect, "Dest", PdfDestinations.ToObject(document, destination) ?? throw new ArgumentException("The destination has no page in the document.", nameof(destination)), style);

    public PdfAnnotation AddLink(PdfPage page, PdfRect rect, PdfAction action, AnnotationStyle? style = null) =>
        PlaceLink(page, rect, "A", PdfActions.ToObject(document, action), style);

    private PdfAnnotation PlaceLink(PdfPage page, PdfRect rect, string key, PdfObject target, AnnotationStyle? style)
    {
        var d = new PdfDictionary
        {
            ["Type"] = new PdfName("Annot"),
            ["Subtype"] = new PdfName("Link"),
            ["Rect"] = rect.ToArray(),
            ["F"] = new PdfNumber((long)AnnotationFlags.Print),
            [key] = target,
        };
        if (style is { Width: > 0, Color.Length: > 0 })
        {
            d["C"] = Numbers(style.Color);
            SetBorder(d, style);
            return Place(page, d);
        }
        d["Border"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(0)]);
        return Attach(page, d);
    }
}
