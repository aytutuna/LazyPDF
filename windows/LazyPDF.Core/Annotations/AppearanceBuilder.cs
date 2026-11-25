namespace LazyPDF.Core;

/// <summary>
/// Draws the /AP /N stream of an annotation from its dictionary, so that a new annotation and an
/// edited one go through the same code. The system renderer ignores /CA and /NeedAppearances, so
/// the stream carries opacity, blend mode and everything else itself.
/// </summary>
internal sealed partial class AppearanceBuilder(PdfDocument document, IFontSource? fonts)
{
    public static readonly double[] Yellow = [1, 1, 0];
    public static readonly double[] Red = [1, 0, 0];
    public static readonly double[] Black = [0];

    private PdfFontEmbedder? _embedder;

    private readonly SortedSet<int> _undrawn = [];

    private PdfFontEmbedder Embedder => _embedder ??= new PdfFontEmbedder(document, fonts);

    /// <summary>The characters no font could draw since the last call, once each in code point order; clears them.</summary>
    public string TakeUndrawn()
    {
        string text = string.Concat(_undrawn.Select(char.ConvertFromUtf32));
        _undrawn.Clear();
        return text;
    }

    /// <summary>True for the subtypes this builder can draw.</summary>
    public static bool CanDraw(AnnotationType type) =>
        type is not (AnnotationType.Other or AnnotationType.Popup or AnnotationType.Widget);

    /// <summary>
    /// Replaces the annotation's /AP with a new stream drawn from its other keys. False, and nothing
    /// touched, when the subtype has no appearance of ours or the rectangle has no area.
    /// </summary>
    public bool Apply(PdfDictionary dictionary)
    {
        if (PdfAnnotations.Parse(document, dictionary, null) is not { } a || a.Rect.IsEmpty) return false;
        // Artwork that is not our text box (an image, a foreign stamp) would be lost to a redraw.
        if (a.Type == AnnotationType.Stamp && document.Stream(document.Dict(dictionary, "AP"), "N") is { } art && !art.Dictionary.ContainsKey(StampMark)) return false;
        if (Draw(a) is not { } canvas) return false;
        var stream = canvas.ToStream();
        if (a.Type == AnnotationType.Stamp) stream.Dictionary[StampMark] = new PdfBoolean(true);
        dictionary["AP"] = new PdfDictionary { ["N"] = document.Add(stream) };
        return true;
    }

    private const string StampMark = "LazyPDFText";

    private AppearanceCanvas? Draw(PdfAnnotation a) => a.Type switch
    {
        AnnotationType.Highlight => Highlight(a),
        AnnotationType.Underline => Underline(a, strike: false),
        AnnotationType.StrikeOut => Underline(a, strike: true),
        AnnotationType.Squiggly => Squiggly(a),
        AnnotationType.Square => Shape(a, ellipse: false),
        AnnotationType.Circle => Shape(a, ellipse: true),
        AnnotationType.Line => Line(a),
        AnnotationType.PolyLine => PolyLine(a),
        AnnotationType.Polygon => Polygon(a),
        AnnotationType.Ink => Ink(a),
        AnnotationType.FreeText => FreeText(a),
        AnnotationType.Stamp => Stamp(a),
        AnnotationType.Text => Note(a),
        AnnotationType.Caret => Caret(a),
        AnnotationType.FileAttachment => Attachment(a),
        AnnotationType.Redact => Redact(a),
        AnnotationType.Link => Link(a),
        _ => null,
    };

    private AppearanceCanvas Canvas(PdfAnnotation a) => new(document, a.Rect);

    private static bool Paints(IReadOnlyList<double>? color) => color is { Count: > 0 };
}
