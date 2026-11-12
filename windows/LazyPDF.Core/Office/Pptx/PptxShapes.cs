namespace LazyPDF.Core.Office;

// Shapes, pictures, groups, connectors and tables of a slide, layout or master.
internal sealed partial class PptxReader
{
    private sealed record FillInfo(int? Color, bool Gradient);

    /// <summary>An a:xfrm in points: where the box is, and for a group the box its children are placed in.</summary>
    private sealed record Xfrm(double X, double Y, double Width, double Height, double ChildX, double ChildY, double ChildWidth, double ChildHeight, double Rotation, bool FlipH, bool FlipV);

    /// <summary>A box turned back upright: the corner, size, and the turn clockwise in degrees (after mirroring left to right).</summary>
    private readonly record struct Upright(double X, double Y, double Width, double Height, double Rotation, bool FlipH)
    {
        public bool Turned => Rotation > 0.01 && Rotation < 359.99;
    }

    private sealed class LineInfo
    {
        public double? Width;
        public int? Color;
        public bool None;
        public string Dash = "solid";
        public string HeadType = "none", HeadWidth = "med", HeadLength = "med";
        public string TailType = "none", TailWidth = "med", TailLength = "med";
    }

    private List<PptxShape> Static(Template template, Scope scope) => Shapes(template.Root, scope, place: false);

    // The shapes of a slide, layout or master that can be drawn. On a layout or master the placeholders are only templates.
    private List<PptxShape> Shapes(XmlElement root, Scope scope, bool place)
    {
        var list = new List<PptxShape>();
        int seen = 0;
        Walk(Children(Tree(root)), scope, place, Affine.Identity, 0, list, ref seen);
        return list;
    }

    private void Walk(IEnumerable<XmlElement> elements, Scope scope, bool place, Affine context, int depth, List<PptxShape> list, ref int seen)
    {
        foreach (var e in elements)
        {
            if (e.Uri != P || e.Name is "nvGrpSpPr" or "grpSpPr" or "extLst") continue;
            if (e.Name == "sp" && !place && PlaceholderOf(e) is not null) continue;
            if (++seen > _limits.MaxShapes)
            {
                Skip(PptxSkipped.Shape);
                continue;
            }
            _cancellation.ThrowIfCancellationRequested();
            switch (e.Name)
            {
                case "sp":
                case "cxnSp":
                    if (Shape(e, scope, context) is { } shape) list.Add(shape);
                    break;
                case "pic":
                    if (Pic(e, scope, context) is { } picture) list.Add(picture);
                    break;
                case "grpSp":
                    Group(e, scope, place, context, depth, list, ref seen);
                    break;
                case "graphicFrame":
                    if (GraphicFrame(e, scope, context) is { } frame) list.Add(frame);
                    break;
                default:
                    Skip(PptxSkipped.Shape);
                    break;
            }
        }
    }

    private void Group(XmlElement group, Scope scope, bool place, Affine context, int depth, List<PptxShape> list, ref int seen)
    {
        if (depth >= _limits.MaxGroupDepth || ReadXfrm(group.Child(P, "grpSpPr")?.Child(DocxReader.A, "xfrm")) is not { } x)
        {
            Skip(PptxSkipped.Shape);
            return;
        }
        var scale = Affine.Scale(x.ChildWidth > 0 ? x.Width / x.ChildWidth : 1, x.ChildHeight > 0 ? x.Height / x.ChildHeight : 1);
        var inner = context.Multiply(Placement(x)).Multiply(scale).Multiply(Affine.Translate(-x.ChildX, -x.ChildY));
        Walk(Children(group), scope, place, inner, depth + 1, list, ref seen);
    }

    // ---- positions ----

    private static Xfrm? ReadXfrm(XmlElement? xfrm)
    {
        var offset = xfrm?.Child(DocxReader.A, "off");
        var extent = xfrm?.Child(DocxReader.A, "ext");
        if (DocxReader.Number(offset?.Attribute("x")) is not { } x || DocxReader.Number(offset!.Attribute("y")) is not { } y
            || DocxReader.Number(extent?.Attribute("cx")) is not { } cx || DocxReader.Number(extent!.Attribute("cy")) is not { } cy)
        {
            return null;
        }
        const double Far = 1e9;
        double Emu(double v, double min) => Math.Clamp(v, min, Far) / EmuPerPoint;
        double width = Emu(cx, 0), height = Emu(cy, 0), left = Emu(x, -Far), top = Emu(y, -Far);
        var childOffset = xfrm!.Child(DocxReader.A, "chOff");
        var childExtent = xfrm.Child(DocxReader.A, "chExt");
        bool hasChildren = childOffset is not null && childExtent is not null;
        return new Xfrm(left, top, width, height,
            hasChildren ? Emu(DocxReader.Number(childOffset!.Attribute("x")) ?? 0, -Far) : left,
            hasChildren ? Emu(DocxReader.Number(childOffset!.Attribute("y")) ?? 0, -Far) : top,
            hasChildren ? Emu(DocxReader.Number(childExtent!.Attribute("cx")) ?? 0, 0) : width,
            hasChildren ? Emu(DocxReader.Number(childExtent!.Attribute("cy")) ?? 0, 0) : height,
            (DocxReader.Number(xfrm.Attribute("rot")) ?? 0) / 60000,
            PptxRunProps.Flag(xfrm.Attribute("flipH")) == true,
            PptxRunProps.Flag(xfrm.Attribute("flipV")) == true);
    }

    // Takes the box 0, 0 to width, height to where the xfrm puts it: mirrored, then turned about its center.
    private static Affine Placement(Xfrm x)
    {
        if (x.Rotation == 0 && !x.FlipH && !x.FlipV) return Affine.Translate(x.X, x.Y);
        return Affine.Translate(x.X + x.Width / 2, x.Y + x.Height / 2)
            .Multiply(Affine.Rotate(x.Rotation))
            .Multiply(Affine.Scale(x.FlipH ? -1 : 1, x.FlipV ? -1 : 1))
            .Multiply(Affine.Translate(-x.Width / 2, -x.Height / 2));
    }

    // What a box of width x height placed by the transform looks like turned back upright.
    private static Upright Uncover(Affine m, double w, double h)
    {
        double width = Affine.Length(m.A, m.B) * w, height = Affine.Length(m.C, m.D) * h;
        double det = m.A * m.D - m.B * m.C;
        double angle = Math.Atan2(m.B, m.A) * 180 / Math.PI - (det < 0 ? 180 : 0);
        angle %= 360;
        if (angle < 0) angle += 360;
        if (m.B == 0 && m.C == 0) return new Upright(m.A >= 0 ? m.E : m.E + m.A * w, m.D >= 0 ? m.F : m.F + m.D * h, width, height, angle, det < 0);
        var (cx, cy) = m.Apply(w / 2, h / 2);
        return new Upright(cx - width / 2, cy - height / 2, width, height, angle, det < 0);
    }

    private static PathCommand Place(Affine m, PathCommand c)
    {
        switch (c.Op)
        {
            case PathOp.Move:
            case PathOp.Line:
            {
                var (x, y) = m.Apply(c.X, c.Y);
                return new PathCommand(c.Op, X: x, Y: y);
            }
            case PathOp.Curve:
            {
                var (x1, y1) = m.Apply(c.X1, c.Y1);
                var (x2, y2) = m.Apply(c.X2, c.Y2);
                var (x, y) = m.Apply(c.X, c.Y);
                return PathCommand.Curve(x1, y1, x2, y2, x, y);
            }
            default:
                return c;
        }
    }

    // ---- fills and lines ----

    private FillInfo? FillOf(XmlElement? spPr, PptxColors colors)
    {
        foreach (var e in spPr?.Elements() ?? [])
        {
            if (e.Uri != DocxReader.A) continue;
            switch (e.Name)
            {
                case "noFill": return new FillInfo(null, false);
                case "solidFill": return new FillInfo(colors.First(e), false);
                case "gradFill": return new FillInfo(colors.First(e.Child(DocxReader.A, "gsLst")?.Child(DocxReader.A, "gs")), true);
                case "blipFill": case "pattFill": case "grpFill": return new FillInfo(null, false);
            }
        }
        return null;
    }

    private static void ApplyLine(LineInfo info, XmlElement? ln, PptxColors colors, int? placeholder)
    {
        if (ln is null) return;
        if (DocxReader.Number(ln.Attribute("w")) is { } width) info.Width = Math.Clamp(width / EmuPerPoint, 0, 1584);
        foreach (var e in ln.Elements())
        {
            if (e.Uri != DocxReader.A) continue;
            switch (e.Name)
            {
                case "noFill":
                    info.None = true;
                    info.Color = null;
                    break;
                case "solidFill":
                    info.None = false;
                    info.Color = colors.First(e, placeholder);
                    break;
                case "gradFill":
                    info.None = false;
                    info.Color = colors.First(e.Child(DocxReader.A, "gsLst")?.Child(DocxReader.A, "gs"), placeholder);
                    break;
                case "prstDash": info.Dash = e.Attribute("val") ?? "solid"; break;
                case "custDash": info.Dash = "dash"; break;
                case "headEnd": (info.HeadType, info.HeadWidth, info.HeadLength) = (e.Attribute("type") ?? "none", e.Attribute("w") ?? "med", e.Attribute("len") ?? "med"); break;
                case "tailEnd": (info.TailType, info.TailWidth, info.TailLength) = (e.Attribute("type") ?? "none", e.Attribute("w") ?? "med", e.Attribute("len") ?? "med"); break;
            }
        }
    }

    // The outline of a shape: the theme line the style points at, then the master's, the layout's and the shape's own line over it.
    private static LineInfo? LineOf(XmlElement? spPr, XmlElement? layoutPr, XmlElement? masterPr, XmlElement? style, Scope scope)
    {
        var info = new LineInfo();
        if (style?.Child(DocxReader.A, "lnRef") is { } reference && DocxReader.Number(reference.Attribute("idx")) is { } idx and > 0)
        {
            int? color = scope.Colors.First(reference);
            var entry = scope.Master.Theme?.Child(DocxReader.A, "themeElements")?.Child(DocxReader.A, "fmtScheme")?.Child(DocxReader.A, "lnStyleLst")?.Elements().ElementAtOrDefault((int)Math.Min(idx, 1000) - 1);
            info.Color = color;
            info.Width = 0.75;
            ApplyLine(info, entry, scope.Colors, color);
        }
        foreach (var layer in new[] { masterPr, layoutPr, spPr }) ApplyLine(info, layer?.Child(DocxReader.A, "ln"), scope.Colors, null);
        return info.None || info.Color is null ? null : info;
    }

    private static double[] Dash(string name, double width)
    {
        double[] pattern = name switch
        {
            "dot" => [1, 3],
            "sysDot" => [1, 1],
            "dash" or "custDash" => [4, 3],
            "sysDash" => [3, 1],
            "lgDash" => [8, 3],
            "dashDot" => [4, 3, 1, 3],
            "sysDashDot" => [3, 1, 1, 1],
            "lgDashDot" => [8, 3, 1, 3],
            "lgDashDotDot" => [8, 3, 1, 3, 1, 3],
            "sysDashDotDot" => [3, 1, 1, 1, 1, 1],
            _ => [],
        };
        double unit = Math.Max(width, 0.25);
        return [.. pattern.Select(p => p * unit)];
    }

    private static PathStroke Stroke(LineInfo line)
    {
        double width = Math.Max(line.Width ?? 0.75, 0.25);
        return new PathStroke(width, line.Color!.Value, Dash(line.Dash, width));
    }

    private static Dictionary<string, double> Adjust(XmlElement? geometry)
    {
        var values = new Dictionary<string, double>(StringComparer.Ordinal);
        foreach (var gd in geometry?.Child(DocxReader.A, "avLst")?.Elements(DocxReader.A, "gd").Take(8) ?? [])
        {
            string? formula = gd.Attribute("fmla");
            if (gd.Attribute("name") is { } name && formula is not null && formula.StartsWith("val ", StringComparison.Ordinal) && DocxReader.Number(formula[4..]) is { } v)
            {
                values[name] = v;
            }
        }
        return values;
    }

    // ---- sp and cxnSp ----

    private PptxShape? Shape(XmlElement sp, Scope scope, Affine context)
    {
        var spPr = sp.Child(P, "spPr");
        var ph = PlaceholderOf(sp);
        Placeholder? layoutPh = null, masterPh = null;
        if (ph is not null)
        {
            string? type = ph.Attribute("type");
            int index = (int)Math.Clamp(DocxReader.Number(ph.Attribute("idx")) ?? 0, 0, int.MaxValue);
            layoutPh = scope.Layout is null ? null : Match(scope.Layout.Placeholders, type, index, true);
            masterPh = Match(scope.Master.Placeholders, layoutPh?.Type ?? type, layoutPh?.Index ?? index, false);
        }
        var layoutPr = layoutPh?.Shape.Child(P, "spPr");
        var masterPr = masterPh?.Shape.Child(P, "spPr");

        var geometry = spPr?.Child(DocxReader.A, "prstGeom") ?? layoutPr?.Child(DocxReader.A, "prstGeom") ?? masterPr?.Child(DocxReader.A, "prstGeom");
        string? preset = geometry?.Attribute("prst");
        bool textBox = sp.Child(P, "nvSpPr")?.Child(P, "cNvSpPr")?.Attribute("txBox") is "1" or "true";
        // A geometry that is not drawn still gives its shape a place for the text.
        bool outline = true;
        if (spPr?.Child(DocxReader.A, "custGeom") is not null)
        {
            Skip(PptxSkipped.CustomGeometry);
            outline = false;
            preset = "rect";
        }
        else if (preset is null)
        {
            if (ph is null && !textBox)
            {
                Skip(PptxSkipped.Shape);
                return null;
            }
            preset = "rect";
        }
        else if (!PptxGeometry.Supports(preset))
        {
            Skip(PptxSkipped.Shape);
            outline = false;
            preset = "rect";
        }
        bool isLine = PptxGeometry.IsLine(preset);

        var style = sp.Child(P, "style");
        var fill = FillOf(spPr, scope.Colors) ?? FillOf(layoutPr, scope.Colors) ?? FillOf(masterPr, scope.Colors);
        int? fillColor = fill?.Color;
        if (fill is null && style?.Child(DocxReader.A, "fillRef") is { } fillRef && DocxReader.Number(fillRef.Attribute("idx")) is > 0) fillColor = scope.Colors.First(fillRef);
        if (!outline || isLine) fillColor = null;
        if (fill is { Gradient: true } && fillColor is not null) Skip(PptxSkipped.Gradient);
        var line = outline ? LineOf(spPr, layoutPr, masterPr, style, scope) : null;

        var body = sp.Child(P, "txBody") is { } txBody ? Body(txBody, ph, layoutPh, masterPh, scope, style) : null;
        if (fillColor is null && body is null && line is null) return null;

        if (ReadXfrm(spPr?.Child(DocxReader.A, "xfrm") ?? layoutPr?.Child(DocxReader.A, "xfrm") ?? masterPr?.Child(DocxReader.A, "xfrm")) is not { } x)
        {
            Skip(PptxSkipped.Shape);
            return null;
        }
        if (spPr?.Child(DocxReader.A, "effectLst")?.Elements().Any() == true || spPr?.Child(DocxReader.A, "scene3d") is not null || spPr?.Child(DocxReader.A, "sp3d") is not null)
        {
            Skip(PptxSkipped.Effect);
        }

        var matrix = context.Multiply(Placement(x));
        var frame = Uncover(matrix, x.Width, x.Height);
        if (body is not null && frame.Turned) Skip(PptxSkipped.TextRotation);

        // A rectangle with a plain fill, upright, is drawn as the box itself; anything else as an outline.
        bool plain = preset == "rect" && line is null && matrix.B == 0 && matrix.C == 0 && matrix.A > 0 && matrix.D > 0;
        var paths = new List<PlacedPath>();
        if (!plain && (fillColor is not null || line is not null))
        {
            var commands = PptxGeometry.Build(preset, x.Width, x.Height, Adjust(geometry)).Select(c => Place(matrix, c)).ToList();
            var stroke = line is null ? null : Stroke(line);
            if (isLine && stroke is not null) Arrowheads(commands, line!, stroke, paths);
            paths.Insert(0, new PlacedPath(commands, fillColor, stroke));
        }

        return new PptxShape
        {
            X = frame.X,
            Y = frame.Y,
            Width = frame.Width,
            Height = frame.Height,
            Fill = plain ? fillColor : null,
            Paths = paths,
            Body = body,
        };
    }

    // The heads at the two ends of a line, which also shorten the line so that its stroke does not poke through them.
    private static void Arrowheads(List<PathCommand> line, LineInfo info, PathStroke stroke, List<PlacedPath> paths)
    {
        double x0 = line[0].X, y0 = line[0].Y, x1 = line[1].X, y1 = line[1].Y;
        double length = Affine.Length(x1 - x0, y1 - y0);
        if (length < 0.01) return;
        double dx = (x1 - x0) / length, dy = (y1 - y0) / length;
        double back0 = Head(info.HeadType, info.HeadWidth, info.HeadLength, x0, y0, -dx, -dy, stroke, paths);
        double back1 = Head(info.TailType, info.TailWidth, info.TailLength, x1, y1, dx, dy, stroke, paths);
        line[0] = PathCommand.Move(x0 + dx * back0, y0 + dy * back0);
        line[1] = PathCommand.Line(x1 - dx * back1, y1 - dy * back1);
    }

    // One head with its tip at (x, y) pointing along (dx, dy); returns how far the line has to stop short of the tip.
    private static double Head(string type, string widthName, string lengthName, double x, double y, double dx, double dy, PathStroke stroke, List<PlacedPath> paths)
    {
        if (type is not ("triangle" or "stealth" or "diamond" or "oval" or "arrow")) return 0;
        double unit = Math.Max(stroke.Width, 2);
        double Size(string name) => name switch { "sm" => 2, "lg" => 5, _ => 3 } * unit;
        double width = Size(widthName), length = Size(lengthName);
        // u is the distance back from the tip along the line, v the distance to the side.
        (double, double) At(double u, double v) => (x - dx * u - dy * v, y - dy * u + dx * v);
        PathCommand Move((double X, double Y) p) => PathCommand.Move(p.X, p.Y);
        PathCommand Line((double X, double Y) p) => PathCommand.Line(p.X, p.Y);
        var solid = new PathStroke(stroke.Width, stroke.Color, []);
        switch (type)
        {
            case "triangle":
                paths.Add(new PlacedPath([Move(At(0, 0)), Line(At(length, -width / 2)), Line(At(length, width / 2)), PathCommand.Close()], stroke.Color, null));
                return length;
            case "stealth":
                paths.Add(new PlacedPath([Move(At(0, 0)), Line(At(length, -width / 2)), Line(At(length * 0.65, 0)), Line(At(length, width / 2)), PathCommand.Close()], stroke.Color, null));
                return length * 0.5;
            case "diamond":
                paths.Add(new PlacedPath([Move(At(0, 0)), Line(At(length / 2, -width / 2)), Line(At(length, 0)), Line(At(length / 2, width / 2)), PathCommand.Close()], stroke.Color, null));
                return length / 2;
            case "oval":
            {
                double ka = length / 2 * 0.5522847498307936, kb = width / 2 * 0.5522847498307936, mid = length / 2, side = width / 2;
                PathCommand Curve((double, double) a, (double, double) b, (double, double) to) => PathCommand.Curve(a.Item1, a.Item2, b.Item1, b.Item2, to.Item1, to.Item2);
                paths.Add(new PlacedPath(
                [
                    Move(At(0, 0)),
                    Curve(At(0, kb), At(mid - ka, side), At(mid, side)),
                    Curve(At(mid + ka, side), At(length, kb), At(length, 0)),
                    Curve(At(length, -kb), At(mid + ka, -side), At(mid, -side)),
                    Curve(At(mid - ka, -side), At(0, -kb), At(0, 0)),
                    PathCommand.Close(),
                ], stroke.Color, null));
                return length / 2;
            }
            default:
                paths.Add(new PlacedPath([Move(At(length, -width / 2)), Line(At(0, 0)), Line(At(length, width / 2))], null, solid));
                return 0;
        }
    }
}
