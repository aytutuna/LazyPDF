namespace LazyPDF.Core;

/// <summary>
/// The form XObject of an appearance stream being drawn. Callers give page coordinates; the form's
/// own space starts at the annotation's lower left corner, so moving the annotation changes /Rect
/// and nothing else (12.5.5).
/// </summary>
internal sealed class AppearanceCanvas
{
    private readonly PdfDocument _document;
    private readonly PdfDictionary _resources = new();
    private string? _state;

    public AppearanceCanvas(PdfDocument document, PdfRect rect)
    {
        _document = document;
        Rect = rect;
    }

    public PdfRect Rect { get; }
    public ContentWriter W { get; } = new();

    public double X(double x) => x - Rect.Left;
    public double Y(double y) => y - Rect.Bottom;

    public AppearanceCanvas Move(double x, double y)
    {
        W.MoveTo(X(x), Y(y));
        return this;
    }

    public AppearanceCanvas Line(double x, double y)
    {
        W.LineTo(X(x), Y(y));
        return this;
    }

    public AppearanceCanvas Curve(double x1, double y1, double x2, double y2, double x3, double y3)
    {
        W.CurveTo(X(x1), Y(y1), X(x2), Y(y2), X(x3), Y(y3));
        return this;
    }

    public AppearanceCanvas Polyline(IReadOnlyList<(double X, double Y)> points, bool close)
    {
        for (int i = 0; i < points.Count; i++)
        {
            if (i == 0) Move(points[i].X, points[i].Y);
            else Line(points[i].X, points[i].Y);
        }
        if (close && points.Count > 0) W.Close();
        return this;
    }

    public AppearanceCanvas Ellipse(double left, double bottom, double right, double top)
    {
        const double Kappa = 0.5522847498;
        double cx = (left + right) / 2, cy = (bottom + top) / 2, rx = (right - left) / 2, ry = (top - bottom) / 2;
        Move(cx + rx, cy);
        Curve(cx + rx, cy + ry * Kappa, cx + rx * Kappa, cy + ry, cx, cy + ry);
        Curve(cx - rx * Kappa, cy + ry, cx - rx, cy + ry * Kappa, cx - rx, cy);
        Curve(cx - rx, cy - ry * Kappa, cx - rx * Kappa, cy - ry, cx, cy - ry);
        Curve(cx + rx * Kappa, cy - ry, cx + rx, cy - ry * Kappa, cx + rx, cy);
        W.Close();
        return this;
    }

    /// <summary>Sets the fill or stroke colour; false for an empty (transparent) colour, which paints nothing.</summary>
    public bool Color(IReadOnlyList<double>? color, bool stroke)
    {
        switch (color?.Count)
        {
            case 1:
                if (stroke) W.StrokeGray(color[0]);
                else W.FillGray(color[0]);
                return true;
            case 3:
                if (stroke) W.StrokeRgb(color[0], color[1], color[2]);
                else W.FillRgb(color[0], color[1], color[2]);
                return true;
            case 4:
                if (stroke) W.StrokeCmyk(color[0], color[1], color[2], color[3]);
                else W.FillCmyk(color[0], color[1], color[2], color[3]);
                return true;
            default:
                return false;
        }
    }

    public AppearanceCanvas Stroke(double width, IReadOnlyList<double>? dash)
    {
        W.LineWidth(width);
        if (dash is { Count: > 0 })
        {
            W.Op("d", [new PdfArray([.. dash.Select(n => (PdfObject)new PdfNumber(n))]), new PdfNumber(0L)]);
        }
        return this;
    }

    /// <summary>
    /// Opacity and blend mode through an /ExtGState of the form itself, because the system renderer
    /// ignores the annotation's /CA. Nothing is written for opaque, normal drawing.
    /// </summary>
    public void Transparency(double opacity, bool multiply)
    {
        if (opacity >= 1 && !multiply) return;
        if (_state is null)
        {
            var state = new PdfDictionary
            {
                ["Type"] = new PdfName("ExtGState"),
                ["CA"] = new PdfNumber(opacity),
                ["ca"] = new PdfNumber(opacity),
                ["BM"] = new PdfName(multiply ? "Multiply" : "Normal"),
                ["AIS"] = new PdfBoolean(false),
            };
            _state = ContentResources.Add(_document, _resources, "ExtGState", state, "GS");
        }
        W.GraphicsState(_state);
    }

    public string AddFont(PdfReference font) => ContentResources.Add(_document, _resources, "Font", font, "F");

    public string AddXObject(PdfReference xobject) => ContentResources.Add(_document, _resources, "XObject", xobject, "Im");

    public PdfStream ToStream()
    {
        var dictionary = new PdfDictionary
        {
            ["Type"] = new PdfName("XObject"),
            ["Subtype"] = new PdfName("Form"),
            ["FormType"] = new PdfNumber(1),
            ["BBox"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(Rect.Width), new PdfNumber(Rect.Height)]),
            ["Matrix"] = new PdfArray([new PdfNumber(1), new PdfNumber(0), new PdfNumber(0), new PdfNumber(1), new PdfNumber(0), new PdfNumber(0)]),
            ["Resources"] = _resources,
            ["Filter"] = new PdfName("FlateDecode"),
        };
        return new PdfStream(dictionary, PdfFilterEncoders.Flate(W.ToArray()));
    }
}
