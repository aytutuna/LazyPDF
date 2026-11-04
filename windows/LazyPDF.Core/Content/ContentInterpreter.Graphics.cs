namespace LazyPDF.Core;

// Line state, ExtGState, paths and colour.
public sealed partial class ContentInterpreter
{
    private List<PathSegment> _path = [];
    private double _curX, _curY, _startX, _startY;
    private int _pendingClip;

    private void ResetPath()
    {
        _path.Clear();
        _pendingClip = 0;
    }

    private void SetDash(ContentOperation op)
    {
        if (op.Operands.Count < 2 || op.Operands[^2] is not PdfArray array || op.Operands[^1] is not PdfNumber phase) return;
        _state.Dash = DashArray(array);
        _state.DashPhase = phase.Value;
    }

    private IReadOnlyList<double> DashArray(PdfArray array) =>
        [.. array.Items.Take(64).Select(i => _doc.Resolve(i) is PdfNumber { Value: var v } && double.IsFinite(v) ? v : 0)];

    private void SetExtGState(ContentOperation op)
    {
        if (NameOperand(op) is not { } name || FindResource("ExtGState", name) is not PdfDictionary g) return;
        if (_doc.Number(g, "LW") is { } lw) _state.LineWidth = lw;
        if (_doc.Integer(g, "LC") is { } lc) _state.LineCap = (int)lc;
        if (_doc.Integer(g, "LJ") is { } lj) _state.LineJoin = (int)lj;
        if (_doc.Number(g, "ML") is { } ml) _state.MiterLimit = ml;
        if (_doc.Array(g, "D") is { Items.Count: >= 2 } d && _doc.Resolve(d.Items[0]) is PdfArray dash && _doc.Resolve(d.Items[1]) is PdfNumber phase)
        {
            _state.Dash = DashArray(dash);
            _state.DashPhase = phase.Value;
        }
        if (_doc.Array(g, "Font") is { Items.Count: >= 2 } f && _doc.Resolve(f.Items[0]) is PdfDictionary font && _doc.Resolve(f.Items[1]) is PdfNumber size)
        {
            _state.Font = PdfFont.Get(_doc, font);
            _state.FontSize = size.Value;
        }
        if (_doc.Number(g, "CA") is { } stroke) _state.StrokeAlpha = Math.Clamp(stroke, 0, 1);
        if (_doc.Number(g, "ca") is { } fill) _state.FillAlpha = Math.Clamp(fill, 0, 1);
        var blend = _doc.Resolve(g["BM"]);
        if (blend is PdfArray { Items.Count: > 0 } modes) blend = _doc.Resolve(modes.Items[0]);
        if (blend is PdfName mode) _state.BlendMode = mode.Value;
        if (g.ContainsKey("SMask")) _state.SoftMask = _doc.Resolve(g["SMask"]) as PdfDictionary;
    }

    private void BuildPath(ContentOperation op)
    {
        var ctm = _state.Ctm;
        Span<double> p = stackalloc double[6];
        switch (op.Operator)
        {
            case "m":
                if (!Numbers(op, p[..2])) return;
                (_startX, _startY) = (_curX, _curY) = ctm.Transform(p[0], p[1]);
                Add(PathSegmentKind.Move, _curX, _curY);
                break;
            case "l":
                if (!Numbers(op, p[..2])) return;
                (_curX, _curY) = ctm.Transform(p[0], p[1]);
                if (_path.Count == 0)
                {
                    (_startX, _startY) = (_curX, _curY);
                    Add(PathSegmentKind.Move, _curX, _curY);
                }
                else Add(PathSegmentKind.Line, _curX, _curY);
                break;
            case "c":
                if (!Numbers(op, p) || _path.Count == 0) return;
                Curve(ctm.Transform(p[0], p[1]), ctm.Transform(p[2], p[3]), ctm.Transform(p[4], p[5]));
                break;
            case "v":
                if (!Numbers(op, p[..4]) || _path.Count == 0) return;
                Curve((_curX, _curY), ctm.Transform(p[0], p[1]), ctm.Transform(p[2], p[3]));
                break;
            case "y":
                if (!Numbers(op, p[..4]) || _path.Count == 0) return;
                var end = ctm.Transform(p[2], p[3]);
                Curve(ctm.Transform(p[0], p[1]), end, end);
                break;
            case "h":
                if (_path.Count == 0) return;
                Add(PathSegmentKind.Close, 0, 0);
                (_curX, _curY) = (_startX, _startY);
                break;
            case "re":
                if (!Numbers(op, p[..4])) return;
                var a = ctm.Transform(p[0], p[1]);
                var b = ctm.Transform(p[0] + p[2], p[1]);
                var c = ctm.Transform(p[0] + p[2], p[1] + p[3]);
                var d = ctm.Transform(p[0], p[1] + p[3]);
                Add(PathSegmentKind.Move, a.X, a.Y);
                Add(PathSegmentKind.Line, b.X, b.Y);
                Add(PathSegmentKind.Line, c.X, c.Y);
                Add(PathSegmentKind.Line, d.X, d.Y);
                Add(PathSegmentKind.Close, 0, 0);
                (_startX, _startY) = (_curX, _curY) = a;
                break;
        }
    }

    private void Add(PathSegmentKind kind, double x, double y)
    {
        if (_path.Count < MaxSegments) _path.Add(new PathSegment(kind, x, y, 0, 0, 0, 0));
    }

    private void Curve((double X, double Y) c1, (double X, double Y) c2, (double X, double Y) end)
    {
        if (_path.Count < MaxSegments) _path.Add(new PathSegment(PathSegmentKind.Curve, c1.X, c1.Y, c2.X, c2.Y, end.X, end.Y));
        (_curX, _curY) = end;
    }

    private void PaintPath(string op)
    {
        bool close = op is "s" or "b" or "b*";
        bool fill = op is "f" or "F" or "f*" or "B" or "B*" or "b" or "b*";
        bool stroke = op is "S" or "s" or "B" or "B*" or "b" or "b*";
        if (_path.Count > 0)
        {
            if (close) Add(PathSegmentKind.Close, 0, 0);
            var bounds = PathBounds();
            if (fill || stroke || _pendingClip != 0)
            {
                double grow = stroke ? Math.Max(_state.LineWidth, 0) * _state.Ctm.ScaleFactor / 2 : 0;
                var ink = new PdfRect(bounds.Left - grow, bounds.Bottom - grow, bounds.Right + grow, bounds.Top + grow);
                _visitor.PaintPath(_context, new PathInfo(op, [.. _path], bounds, ink, fill, stroke, op is "f*" or "B*" or "b*", _pendingClip != 0));
                if (fill) WalkPattern(_state.FillColor);
                if (stroke) WalkPattern(_state.StrokeColor);
            }
            if (_pendingClip != 0) _state.Clip = _state.Clip.Intersect(bounds);
        }
        ResetPath();
    }

    private PdfRect PathBounds()
    {
        double x1 = double.MaxValue, y1 = double.MaxValue, x2 = double.MinValue, y2 = double.MinValue;
        void Include(double x, double y)
        {
            x1 = Math.Min(x1, x);
            y1 = Math.Min(y1, y);
            x2 = Math.Max(x2, x);
            y2 = Math.Max(y2, y);
        }
        foreach (var s in _path)
        {
            if (s.Kind == PathSegmentKind.Close) continue;
            Include(s.X1, s.Y1);
            if (s.Kind != PathSegmentKind.Curve) continue;
            Include(s.X2, s.Y2);
            Include(s.X3, s.Y3);
        }
        return x1 > x2 ? new PdfRect(0, 0, 0, 0) : new PdfRect(x1, y1, x2, y2);
    }

    private void SetDeviceColor(ContentOperation op)
    {
        var space = op.Operator[0] switch
        {
            'g' or 'G' => ColorSpaceInfo.DeviceGray,
            'r' or 'R' => ColorSpaceInfo.DeviceRgb,
            _ => ColorSpaceInfo.DeviceCmyk,
        };
        var values = new double[space.Components];
        if (!Numbers(op, values)) return;
        var color = new PdfColor(space, values);
        if (char.IsUpper(op.Operator[0])) _state.StrokeColor = color;
        else _state.FillColor = color;
    }

    private void SetColorSpace(ContentOperation op)
    {
        if (NameOperand(op) is not { } name) return;
        var space = ResolveSpace(name);
        var color = new PdfColor(space, space.InitialColor());
        if (op.Operator == "CS") _state.StrokeColor = color;
        else _state.FillColor = color;
    }

    private ColorSpaceInfo ResolveSpace(string name)
    {
        switch (name)
        {
            case "DeviceGray" or "G": return ColorSpaceInfo.DeviceGray;
            case "DeviceRGB" or "RGB": return ColorSpaceInfo.DeviceRgb;
            case "DeviceCMYK" or "CMYK": return ColorSpaceInfo.DeviceCmyk;
        }
        var definition = name == "Pattern" ? new PdfName(name) : FindResource("ColorSpace", name);
        if (definition is null) return ColorSpaceInfo.DeviceGray;
        if (!_colorSpaces.TryGetValue(definition, out var space))
        {
            space = ColorSpaceInfo.Create(_doc, definition);
            if (_colorSpaces.Count < 256) _colorSpaces[definition] = space;
        }
        return space;
    }

    private void SetColor(ContentOperation op)
    {
        bool stroke = op.Operator[0] == 'S';
        var space = stroke ? _state.StrokeColor.Space : _state.FillColor.Space;
        var values = op.Operands.OfType<PdfNumber>().Take(32).Select(n => n.Value).ToArray();
        PdfColor color;
        if (space.Family == "Pattern")
        {
            var patternName = op.Operands.Count > 0 ? op.Operands[^1] as PdfName : null;
            var pattern = patternName is null ? null : FindResource("Pattern", patternName.Value);
            color = new PdfColor(space, values, patternName, pattern);
        }
        else if (values.Length > 0)
        {
            color = new PdfColor(space, values);
        }
        else return;
        if (stroke) _state.StrokeColor = color;
        else _state.FillColor = color;
    }
}
