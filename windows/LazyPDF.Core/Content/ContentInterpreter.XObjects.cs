namespace LazyPDF.Core;

// Images, shadings, forms, tiling patterns and marked content.
public sealed partial class ContentInterpreter
{
    private const int MaxMarkedDepth = 1024;

    private static readonly MarkedContent Overflow = new("", null, null, null);

    private IReadOnlyList<ContentOperation>? Operations(PdfStream stream)
    {
        if (_formOperations.TryGetValue(stream, out var cached)) return cached;
        IReadOnlyList<ContentOperation> operations;
        long size = 0;
        try
        {
            var data = _doc.Data(stream, MaxFormSize);
            size = data.Length;
            operations = ContentParser.Parse(data, MaxFormOperations);
        }
        catch (PdfReadException)
        {
            operations = [];
        }
        if (_formOperations.Count < MaxCachedForms && _cachedOperations + operations.Count <= MaxCachedOperations)
        {
            _formOperations[stream] = operations;
            _cachedOperations += operations.Count;
        }
        else
        {
            // Not kept, so every Do of it inflates and scans the stream again.
            _budget -= size >> 6;
        }
        return operations;
    }

    private void Paint(ContentOperation op)
    {
        if (NameOperand(op) is not { } name || FindResource("XObject", name) is not PdfStream xobject) return;
        string? subtype = _doc.Name(xobject.Dictionary, "Subtype");
        if (subtype == "Image") PaintImage(name, xobject, null, xobject.Dictionary);
        else if (subtype == "Form" || (subtype is null && xobject.Dictionary.ContainsKey("BBox"))) EnterForm(xobject, name, _doc.Dict(xobject.Dictionary, "OC"));
    }

    private void PaintInlineImage(ContentOperation op)
    {
        if (op.Image is not { } image) return;
        var dictionary = image.Expanded(name => FindResource("ColorSpace", name));
        PaintImage(null, null, image, dictionary);
    }

    private void PaintImage(string? name, PdfStream? stream, InlineImage? inline, PdfDictionary dictionary)
    {
        int width = (int)Math.Clamp(_doc.Integer(dictionary, "Width") ?? 0, 0, int.MaxValue);
        int height = (int)Math.Clamp(_doc.Integer(dictionary, "Height") ?? 0, 0, int.MaxValue);
        var bounds = _state.Ctm.Transform(new PdfRect(0, 0, 1, 1));
        _visitor.PaintImage(_context, new ImageInfo(name, stream, inline, dictionary, width, height,
            _doc.Bool(dictionary, "ImageMask") == true, _state.Ctm, bounds, _doc.Dict(dictionary, "OC")));
    }

    private void PaintShading(ContentOperation op)
    {
        if (NameOperand(op) is { } name && FindResource("Shading", name) is PdfObject shading and (PdfDictionary or PdfStream))
            _visitor.PaintShading(_context, new ShadingInfo(name, shading, _state.Clip));
    }

    private void EnterForm(PdfStream form, string? name, PdfDictionary? optionalContent)
    {
        var inner = _state.Clone();
        var matrix = PdfMatrix.FromArray(_doc.Array(form.Dictionary, "Matrix"), _doc.Resolve) ?? PdfMatrix.Identity;
        inner.Ctm = matrix.Multiply(inner.Ctm);
        RunContent(form, name, false, inner, optionalContent);
    }

    // A tiling pattern's cell is run once, when something is first painted with it (8.7.3).
    private void WalkPattern(PdfColor color)
    {
        if (!WalkPatterns || color.Pattern is not PdfStream pattern || _doc.Integer(pattern.Dictionary, "PatternType") != 1) return;
        if (!_walkedPatterns.Add(pattern)) return;
        var matrix = PdfMatrix.FromArray(_doc.Array(pattern.Dictionary, "Matrix"), _doc.Resolve) ?? PdfMatrix.Identity;
        var inner = new GraphicsState { Ctm = matrix.Multiply(_base), Clip = Unbounded };
        if (_doc.Integer(pattern.Dictionary, "PaintType") == 2)
        {
            inner.FillColor = inner.StrokeColor = new PdfColor(color.Space.Base ?? ColorSpaceInfo.DeviceGray, [.. color.Components]);
        }
        RunContent(pattern, color.PatternName?.Value, true, inner, null);
    }

    private void RunContent(PdfStream stream, string? name, bool isPattern, GraphicsState inner, PdfDictionary? optionalContent)
    {
        if (_forms.Count >= MaxFormDepth || _activeForms.Contains(stream) || Operations(stream) is not { } operations) return;
        _activeForms.Add(stream);
        var outer = (State: _state, Stack: _stack, Base: _base, Tm: _tm, Tlm: _tlm, Path: _path, Clip: _pendingClip);
        var bbox = _doc.Rect(stream.Dictionary, "BBox");
        var area = bbox is { } b ? inner.Ctm.Transform(b) : inner.Clip;
        if (bbox is not null) inner.Clip = inner.Clip.Intersect(area);
        _state = inner;
        _context.State = inner;
        _stack = [];
        _base = inner.Ctm;
        _path = [];
        ResetPath();
        _resources.Add(_doc.Dict(stream.Dictionary, "Resources"));
        _forms.Add(stream);
        var info = new FormInfo(stream, name, inner.Ctm, area, isPattern, optionalContent);
        int index = _context.OperatorIndex;
        var operation = _context.Operation;
        _visitor.BeginForm(_context, info);
        Execute(operations);
        _context.OperatorIndex = index;
        _context.Operation = operation;
        _visitor.EndForm(_context, info);
        _forms.RemoveAt(_forms.Count - 1);
        _resources.RemoveAt(_resources.Count - 1);
        (_state, _stack, _base, _tm, _tlm) = (outer.State, outer.Stack, outer.Base, outer.Tm, outer.Tlm);
        _context.State = _state;
        _path = outer.Path;
        _pendingClip = outer.Clip;
        SyncText();
        _activeForms.Remove(stream);
    }

    private void BeginMarkedContent(ContentOperation op)
    {
        if (_marked.Count >= MaxMarkedDepth)
        {
            _marked.Add(Overflow);
            return;
        }
        string tag = NameOperand(op) ?? "";
        PdfDictionary? properties = null;
        if (op.Operator == "BDC" && op.Operands.Count >= 2)
        {
            properties = op.Operands[^1] switch
            {
                PdfDictionary inline => inline,
                PdfName key => FindResource("Properties", key.Value) as PdfDictionary,
                _ => null,
            };
        }
        var marked = new MarkedContent(tag, properties, properties is null ? null : _doc.Integer(properties, "MCID") is >= int.MinValue and <= int.MaxValue and var mcid ? (int)mcid : null, tag == "OC" ? properties : null);
        _marked.Add(marked);
        _visitor.BeginMarked(_context, marked);
    }

    private void EndMarkedContent()
    {
        if (_marked.Count <= _markedFloor) return;
        var marked = _marked[^1];
        if (!ReferenceEquals(marked, Overflow)) _visitor.EndMarked(_context, marked);
        _marked.RemoveAt(_marked.Count - 1);
    }
}
