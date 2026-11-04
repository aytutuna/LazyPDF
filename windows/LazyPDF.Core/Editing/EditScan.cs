namespace LazyPDF.Core;

/// <summary>A content stream being edited: the page's content as one piece, or one form XObject.</summary>
internal sealed class ContentUnit(PdfStream? form, byte[] data, IReadOnlyList<ContentOperation> operations)
{
    private OpStates? _states;

    /// <summary>Null for the page.</summary>
    public PdfStream? Form { get; } = form;
    public byte[] Data { get; } = data;
    public IReadOnlyList<ContentOperation> Operations { get; } = operations;
    public OpStates States => _states ??= OpStates.Scan(Operations);

    /// <summary>How many times the walk ran this stream: a form painted twice is edited for both.</summary>
    public int Visits { get; set; }
}

/// <summary>One run of a form XObject inside the walk: where its <c>Do</c> is and what encloses it.</summary>
internal sealed class FormVisit(PdfStream form, FormVisit? parent, ContentUnit parentUnit, int doOperation, string? name, ContentUnit unit)
{
    public PdfStream Form { get; } = form;
    public FormVisit? Parent { get; } = parent;
    public ContentUnit ParentUnit { get; } = parentUnit;
    public int DoOperation { get; } = doOperation;
    public string? Name { get; } = name;
    public ContentUnit Unit { get; } = unit;

    public IReadOnlyList<PdfStream> Chain => Parent is null ? [Form] : [.. Parent.Chain, Form];
}

/// <summary>A shown glyph with everything needed to find and rewrite its bytes.</summary>
internal sealed class EditGlyph
{
    public required ContentUnit Unit { get; init; }
    public FormVisit? Visit { get; init; }
    public int Op { get; init; }
    public int Element { get; init; }
    public int Offset { get; init; }
    public int Length { get; init; }
    public int Sequence { get; init; }

    public required PdfFont Font { get; init; }
    public string Text { get; init; } = "";
    public FontChar Character { get; init; }
    public PdfMatrix Matrix { get; init; }
    public PdfMatrix Ctm { get; init; }
    public PdfMatrix TextMatrix { get; init; }
    public PdfMatrix TextLineMatrix { get; init; }
    public PdfRect Bounds { get; init; }
    public TextQuad Quad { get; init; }

    public double FontSize { get; init; }
    public double Scale { get; init; } = 1;
    public double CharSpacing { get; init; }
    public double WordSpacing { get; init; }
    public double Rise { get; init; }
    public double Leading { get; init; }
    public double Advance { get; init; }
    public int RenderMode { get; init; }
    public RgbColor Color { get; init; }
    public bool HasActualText { get; init; }

    /// <summary>Glyphs drawn again at the same place, which go with it.</summary>
    public List<EditGlyph> Twins { get; } = [];

    /// <summary>The size in user space units the glyph is drawn at.</summary>
    public double UserSize => Math.Sqrt(Matrix.C * Matrix.C + Matrix.D * Matrix.D);

    /// <summary>Where text space lengths along the line become user space lengths.</summary>
    public double UnitX => Math.Sqrt(Math.Pow(TextMatrix.Multiply(Ctm).A, 2) + Math.Pow(TextMatrix.Multiply(Ctm).B, 2));

    public (double X, double Y) Origin => (Matrix.E, Matrix.F);

    /// <summary>The unit vector along the baseline in user space.</summary>
    public (double X, double Y) Direction
    {
        get
        {
            double length = Math.Sqrt(Matrix.A * Matrix.A + Matrix.B * Matrix.B);
            return length < 1e-12 ? (1, 0) : (Matrix.A / length, Matrix.B / length);
        }
    }
}

internal sealed record ImageRecord(ContentUnit Unit, FormVisit? Visit, int Op, ImageInfo Info, double Opacity, int Sequence);

internal sealed record PathRecord(ContentUnit Unit, FormVisit? Visit, int FirstOp, int PaintOp, PathInfo Info, PathStyle Style, int Sequence);

/// <summary>Walks a page once and records every glyph, image and path with the stream and operation it came from.</summary>
internal sealed class EditScan : ContentVisitor
{
    private const long MaxFormSize = 64L << 20;
    private const int MaxFormOperations = 1_000_000;

    private readonly PdfDocument _document;
    private readonly List<FormVisit> _visits = [];
    private int _inPattern;
    private int _sequence;

    public EditScan(PdfDocument document, PdfPage page)
    {
        _document = document;
        byte[] data = page.Contents();
        PageUnit = new ContentUnit(null, data, ContentParser.Parse(data)) { Visits = 1 };
    }

    public ContentUnit PageUnit { get; }
    public Dictionary<PdfStream, ContentUnit> Forms { get; } = [];
    public List<EditGlyph> Glyphs { get; } = [];
    public List<ImageRecord> Images { get; } = [];
    public List<PathRecord> Paths { get; } = [];

    private ContentUnit Current => _visits.Count > 0 ? _visits[^1].Unit : PageUnit;
    private FormVisit? Visit => _visits.Count > 0 ? _visits[^1] : null;

    public override void BeginForm(ContentContext context, FormInfo form)
    {
        if (form.IsPattern || _inPattern > 0)
        {
            _inPattern++;
            return;
        }
        if (!Forms.TryGetValue(form.Stream, out var unit))
        {
            byte[] data = [];
            IReadOnlyList<ContentOperation> operations = [];
            try
            {
                data = _document.Data(form.Stream, MaxFormSize);
                operations = ContentParser.Parse(data, MaxFormOperations);
            }
            catch (PdfReadException)
            {
            }
            unit = new ContentUnit(form.Stream, data, operations);
            Forms[form.Stream] = unit;
        }
        unit.Visits++;
        _visits.Add(new FormVisit(form.Stream, Visit, Current, context.OperatorIndex, form.Name, unit));
    }

    public override void EndForm(ContentContext context, FormInfo form)
    {
        if (_inPattern > 0)
        {
            _inPattern--;
            return;
        }
        _visits.RemoveAt(_visits.Count - 1);
    }

    public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
    {
        if (_inPattern > 0) return;
        var state = context.State;
        var m = glyph.Matrix;
        double ascent = glyph.Font.Ascent > 0 ? Math.Min(glyph.Font.Ascent / 1000, 1.1) : 0.8;
        double descent = glyph.Font.Descent < 0 ? Math.Max(glyph.Font.Descent / 1000, -0.4) : -0.2;
        ascent = Math.Max(ascent, 0.5);
        double width = Math.Max(glyph.Character.Width / 1000, 0);
        var (x0, y0) = m.Transform(0, descent);
        var (x1, y1) = m.Transform(width, descent);
        var (x2, y2) = m.Transform(width, ascent);
        var (x3, y3) = m.Transform(0, ascent);
        Glyphs.Add(new EditGlyph
        {
            Unit = Current,
            Visit = Visit,
            Op = context.OperatorIndex,
            Element = glyph.Element,
            Offset = glyph.Offset,
            Length = glyph.Character.Length,
            Sequence = _sequence++,
            Font = glyph.Font,
            Text = glyph.Unicode ?? "",
            Character = glyph.Character,
            Matrix = m,
            Ctm = state.Ctm,
            TextMatrix = context.TextMatrix,
            TextLineMatrix = context.TextLineMatrix,
            Bounds = glyph.Bounds,
            Quad = new TextQuad(x0, y0, x1, y1, x2, y2, x3, y3),
            FontSize = state.FontSize,
            Scale = state.HorizontalScale,
            CharSpacing = state.CharSpacing,
            WordSpacing = state.WordSpacing,
            Rise = state.Rise,
            Leading = state.Leading,
            Advance = glyph.Advance,
            RenderMode = state.RenderMode,
            Color = (state.RenderMode == 1 ? state.StrokeColor : state.FillColor).Rgb,
            HasActualText = context.Marked.Any(x => x.Properties is not null && x.Properties.ContainsKey("ActualText")),
        });
    }

    public override void PaintImage(ContentContext context, ImageInfo image)
    {
        if (_inPattern > 0) return;
        Images.Add(new ImageRecord(Current, Visit, context.OperatorIndex, image, context.State.FillAlpha, _sequence++));
    }

    public override void PaintPath(ContentContext context, PathInfo path)
    {
        if (_inPattern > 0 || !(path.Fill || path.Stroke)) return;
        var state = context.State;
        var style = new PathStyle(state.FillColor.Rgb, state.StrokeColor.Rgb, state.LineWidth,
            path.Fill ? state.FillAlpha : state.StrokeAlpha, state.Ctm);
        var ops = Current.Operations;
        int paint = context.OperatorIndex;
        int first = paint;
        while (first > 0 && ops[first - 1].Operator is "m" or "l" or "c" or "v" or "y" or "h" or "re" or "W" or "W*") first--;
        Paths.Add(new PathRecord(Current, Visit, first, paint, path, style, _sequence++));
    }
}
