namespace LazyPDF.Core;

/// <summary>
/// An annotation as read (ISO 32000-1 12.5). The values are a snapshot; <see cref="Dictionary"/> is the
/// live dictionary, so keys this layer does not know stay where they are when it is changed or saved.
/// Geometry is in user space.
/// </summary>
public sealed record PdfAnnotation
{
    public required PdfDictionary Dictionary { get; init; }

    /// <summary>Null for an annotation written directly in the page's /Annots array.</summary>
    public PdfReference? Reference { get; init; }

    /// <summary>The page it is on, from 0; -1 when read without one.</summary>
    public int PageIndex { get; init; } = -1;

    public string Subtype { get; init; } = "";
    public AnnotationType Type { get; init; }
    public PdfRect Rect { get; init; }
    public string? Contents { get; init; }
    public string? Title { get; init; }
    public string? Subject { get; init; }
    public string? Name { get; init; }
    public DateTimeOffset? Created { get; init; }
    public DateTimeOffset? Modified { get; init; }
    public AnnotationFlags Flags { get; init; }

    /// <summary>/C: null when absent, empty for transparent, else gray, RGB or CMYK.</summary>
    public IReadOnlyList<double>? Color { get; init; }
    public IReadOnlyList<double>? InteriorColor { get; init; }
    public double Opacity { get; init; } = 1;
    public AnnotationBorder Border { get; init; } = new(1, BorderStyle.Solid, []);

    public PdfReference? InReplyTo { get; init; }

    /// <summary>/RT: "R" (a reply) or "Group".</summary>
    public string? ReplyType { get; init; }

    /// <summary>/State with /StateModel, null when the annotation has none.</summary>
    public ReviewStatus? State { get; init; }

    public IReadOnlyList<double> QuadPoints { get; init; } = [];
    public IReadOnlyList<IReadOnlyList<double>> InkList { get; init; } = [];
    public IReadOnlyList<double> Vertices { get; init; } = [];

    /// <summary>/L: x1 y1 x2 y2, empty when absent.</summary>
    public IReadOnlyList<double> Line { get; init; } = [];
    public LineEnding StartEnding { get; init; }
    public LineEnding EndEnding { get; init; }

    /// <summary>/CL: two or three points of a callout line.</summary>
    public IReadOnlyList<double> Callout { get; init; } = [];
    public string? Intent { get; init; }

    /// <summary>/RD: left, bottom, right, top insets of the drawn shape from <see cref="Rect"/>, empty when absent.</summary>
    public IReadOnlyList<double> RectDifference { get; init; } = [];

    /// <summary>/BE with /S /C: the intensity (0, 1 or 2), 0 when the border is not a cloud.</summary>
    public int Cloud { get; init; }

    public string? DefaultAppearance { get; init; }
    public string? DefaultStyle { get; init; }
    public string? RichText { get; init; }
    public int Alignment { get; init; }
    public string? IconName { get; init; }
    public PdfReference? Popup { get; init; }
    public bool HasAppearance { get; init; }

    /// <summary>The corner points of the quads, as <see cref="MarkupQuad"/>s.</summary>
    public IReadOnlyList<MarkupQuad> Quads
    {
        get
        {
            var quads = new List<MarkupQuad>();
            for (int i = 0; i + 8 <= QuadPoints.Count; i += 8)
            {
                quads.Add(new MarkupQuad(QuadPoints[i], QuadPoints[i + 1], QuadPoints[i + 2], QuadPoints[i + 3],
                    QuadPoints[i + 4], QuadPoints[i + 5], QuadPoints[i + 6], QuadPoints[i + 7]));
            }
            return quads;
        }
    }

    /// <summary>True for the subtypes that carry a comment (12.5.6.2): everything but links, widgets and popups.</summary>
    public bool IsMarkup => Type is not (AnnotationType.Link or AnnotationType.Widget or AnnotationType.Popup or AnnotationType.Other);
}
