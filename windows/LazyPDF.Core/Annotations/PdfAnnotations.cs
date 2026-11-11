namespace LazyPDF.Core;

/// <summary>Reading a page's annotations (ISO 32000-1 12.5).</summary>
public static class PdfAnnotations
{
    internal const int MaxAnnotations = 50_000;
    private const int MaxNumbers = 4_000_000;

    // What one Read has turned into numbers, by the array it came from: an array that many annotations point to is read once
    // and shared, so the cost of a file is its size and not its size times the annotations that name the same array.
    private sealed class Shared
    {
        public readonly Dictionary<PdfArray, double[]> Numbers = new(ReferenceEqualityComparer.Instance);
        public readonly Dictionary<PdfArray, IReadOnlyList<IReadOnlyList<double>>> Inks = new(ReferenceEqualityComparer.Instance);
    }

    private static readonly Dictionary<string, AnnotationType> Types = new(StringComparer.Ordinal)
    {
        ["Text"] = AnnotationType.Text, ["Link"] = AnnotationType.Link, ["FreeText"] = AnnotationType.FreeText,
        ["Line"] = AnnotationType.Line, ["Square"] = AnnotationType.Square, ["Circle"] = AnnotationType.Circle,
        ["Polygon"] = AnnotationType.Polygon, ["PolyLine"] = AnnotationType.PolyLine, ["Highlight"] = AnnotationType.Highlight,
        ["Underline"] = AnnotationType.Underline, ["Squiggly"] = AnnotationType.Squiggly, ["StrikeOut"] = AnnotationType.StrikeOut,
        ["Stamp"] = AnnotationType.Stamp, ["Caret"] = AnnotationType.Caret, ["Ink"] = AnnotationType.Ink,
        ["Popup"] = AnnotationType.Popup, ["FileAttachment"] = AnnotationType.FileAttachment, ["Redact"] = AnnotationType.Redact,
        ["Widget"] = AnnotationType.Widget,
    };

    /// <summary>
    /// Whether the file's permissions let a user annotate: always for an unencrypted file or one opened
    /// with the owner password, else when the Annotate bit is set. Enforcing it is the app's call.
    /// </summary>
    public static bool CanAnnotate(PdfDocument document) =>
        document.Security is not { } security || security.OpenedAsOwner || security.Permissions.HasFlag(PdfPermissions.Annotate);

    public static string SubtypeName(AnnotationType type) => type == AnnotationType.Other ? "" : type.ToString();

    /// <summary>
    /// The page's annotations in /Annots order, at most 50000. Entries that are not dictionaries or have
    /// no /Subtype are left out; every other key is read tolerantly, a bad one falling back to its default.
    /// </summary>
    public static IReadOnlyList<PdfAnnotation> Read(PdfDocument document, PdfPage page) => Read(document, page, new Shared());

    private static List<PdfAnnotation> Read(PdfDocument document, PdfPage page, Shared shared)
    {
        var result = new List<PdfAnnotation>();
        if (document.Array(page.Dictionary, "Annots") is not { } annots) return result;
        foreach (var item in annots.Items)
        {
            if (result.Count >= MaxAnnotations) break;
            if (document.Resolve(item) is PdfDictionary dictionary && Parse(document, dictionary, item as PdfReference, page.Index, shared) is { } annotation)
            {
                result.Add(annotation);
            }
        }
        return result;
    }

    /// <summary>Every annotation of the document, page by page.</summary>
    public static IReadOnlyList<PdfAnnotation> ReadAll(PdfDocument document)
    {
        var result = new List<PdfAnnotation>();
        var shared = new Shared();
        foreach (var page in document.Pages)
        {
            if (result.Count >= MaxAnnotations) break;
            result.AddRange(Read(document, page, shared));
        }
        return result;
    }

    /// <summary>The annotation a dictionary describes; null without a /Subtype name.</summary>
    public static PdfAnnotation? Parse(PdfDocument document, PdfDictionary d, PdfReference? reference, int pageIndex = -1) =>
        Parse(document, d, reference, pageIndex, new Shared());

    private static PdfAnnotation? Parse(PdfDocument document, PdfDictionary d, PdfReference? reference, int pageIndex, Shared shared)
    {
        if (document.Name(d, "Subtype") is not { } subtype) return null;
        var type = Types.GetValueOrDefault(subtype);
        var corners = Numbers(document, d["Rect"], shared);
        var (start, end) = Endings(document, d);
        var be = document.Dict(d, "BE");
        return new PdfAnnotation
        {
            Dictionary = d,
            Reference = reference,
            PageIndex = pageIndex,
            Subtype = subtype,
            Type = type,
            Rect = corners.Length >= 4 ? new PdfRect(corners[0], corners[1], corners[2], corners[3]) : new PdfRect(0, 0, 0, 0),
            Contents = PdfText.Read(document, d, "Contents"),
            Title = PdfText.Read(document, d, "T"),
            Subject = PdfText.Read(document, d, "Subj"),
            Name = PdfText.Read(document, d, "NM"),
            Created = PdfDate.Parse(PdfText.Read(document, d, "CreationDate")),
            Modified = PdfDate.Parse(PdfText.Read(document, d, "M")),
            Flags = (AnnotationFlags)(document.Integer(d, "F") ?? 0),
            Color = ColorOf(document, d["C"], shared),
            InteriorColor = ColorOf(document, d["IC"], shared),
            Opacity = Math.Clamp(document.Number(d, "CA") ?? 1, 0, 1),
            Border = Border(document, d, shared),
            InReplyTo = d["IRT"] as PdfReference,
            ReplyType = document.Name(d, "RT"),
            State = State(document, d),
            QuadPoints = Numbers(document, d["QuadPoints"], shared),
            InkList = InkList(document, d, shared),
            Vertices = Numbers(document, d["Vertices"], shared),
            Line = Numbers(document, d["L"], shared),
            StartEnding = start,
            EndEnding = end,
            Callout = Numbers(document, d["CL"], shared),
            Intent = document.Name(d, "IT"),
            RectDifference = Numbers(document, d["RD"], shared),
            Cloud = be is not null && document.Name(be, "S") == "C" ? (int)Math.Clamp(document.Number(be, "I") ?? 1, 0, 2) : 0,
            DefaultAppearance = PdfText.Read(document, d, "DA"),
            DefaultStyle = PdfText.Read(document, d, "DS"),
            RichText = PdfText.Read(document, d, "RC"),
            Alignment = (int)(document.Integer(d, "Q") ?? 0),
            IconName = (document.Resolve(d["Name"]) as PdfName)?.Text,
            Popup = d["Popup"] as PdfReference,
            HasAppearance = document.Dict(d, "AP") is { } ap && ap["N"] is not null,
        };
    }

    internal static double[] Numbers(PdfDocument document, PdfObject? value) => Numbers(document, value, new Shared());

    private static double[] Numbers(PdfDocument document, PdfObject? value, Shared shared)
    {
        if (document.Resolve(value) is not PdfArray array) return [];
        if (shared.Numbers.TryGetValue(array, out var known)) return known;
        var numbers = new List<double>(Math.Min(array.Items.Count, 64));
        foreach (var item in array.Items.Take(MaxNumbers))
        {
            numbers.Add(document.Resolve(item) is PdfNumber { Value: var v } && double.IsFinite(v) ? v : 0);
        }
        return shared.Numbers[array] = [.. numbers];
    }

    private static double[]? ColorOf(PdfDocument document, PdfObject? value, Shared shared)
    {
        if (document.Resolve(value) is not PdfArray) return null;
        var color = Numbers(document, value, shared);
        return color.Length is 0 or 1 or 3 or 4 ? color : null;
    }

    private static AnnotationBorder Border(PdfDocument document, PdfDictionary d, Shared shared)
    {
        if (document.Dict(d, "BS") is { } bs)
        {
            var style = document.Name(bs, "S") switch
            {
                "D" => BorderStyle.Dashed, "B" => BorderStyle.Beveled, "I" => BorderStyle.Inset, "U" => BorderStyle.Underline,
                _ => BorderStyle.Solid,
            };
            double[] dash = style == BorderStyle.Dashed ? DashOf(Numbers(document, bs["D"], shared)) : [];
            return new AnnotationBorder(Math.Max(0, document.Number(bs, "W") ?? 1), style, dash);
        }
        var border = document.Array(d, "Border");
        if (border is { Items.Count: >= 3 })
        {
            double width = document.Resolve(border.Items[2]) is PdfNumber { Value: var w } ? Math.Max(0, w) : 1;
            double[] dash = border.Items.Count > 3 ? DashOf(Numbers(document, border.Items[3], shared)) : [];
            return new AnnotationBorder(width, dash.Length > 0 ? BorderStyle.Dashed : BorderStyle.Solid, dash);
        }
        return new AnnotationBorder(1, BorderStyle.Solid, []);
    }

    private static double[] DashOf(double[] dash) => dash.Length > 0 ? dash : [3];

    private static ReviewStatus? State(PdfDocument document, PdfDictionary d)
    {
        string? state = PdfText.Read(document, d, "State");
        return state is not null && TryName(state, out ReviewStatus status) ? status : null;
    }

    private static IReadOnlyList<IReadOnlyList<double>> InkList(PdfDocument document, PdfDictionary d, Shared shared)
    {
        if (document.Resolve(d["InkList"]) is not PdfArray list) return [];
        if (shared.Inks.TryGetValue(list, out var known)) return known;
        return shared.Inks[list] = [.. list.Items.Take(MaxAnnotations).Select(item => (IReadOnlyList<double>)Numbers(document, item, shared))];
    }

    private static (LineEnding Start, LineEnding End) Endings(PdfDocument document, PdfDictionary d)
    {
        var value = document.Resolve(d["LE"]);
        if (value is PdfName single) return (LineEndingOf(single.Value), LineEnding.None);
        if (value is not PdfArray { Items.Count: > 0 } array) return (LineEnding.None, LineEnding.None);
        var first = LineEndingOf((document.Resolve(array.Items[0]) as PdfName)?.Value);
        var second = array.Items.Count > 1 ? LineEndingOf((document.Resolve(array.Items[1]) as PdfName)?.Value) : LineEnding.None;
        return (first, second);
    }

    internal static LineEnding LineEndingOf(string? name) =>
        name is not null && TryName(name, out LineEnding ending) ? ending : LineEnding.None;

    // Enum.TryParse also takes numbers, comma lists and text with spaces around it, none of which is a name.
    private static bool TryName<T>(string name, out T value) where T : struct, Enum
    {
        value = default;
        return Enum.IsDefined(typeof(T), name) && Enum.TryParse(name, out value);
    }
}
