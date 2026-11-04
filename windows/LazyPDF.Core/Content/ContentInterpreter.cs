namespace LazyPDF.Core;

/// <summary>
/// Walks the operations of a page or form with the full graphics state (ISO 32000-1 8, 9) and
/// reports glyphs, paths, images, shadings and marked content to a <see cref="ContentVisitor"/>.
/// Form XObjects and tiling patterns are entered, each once per use for forms and once per run for
/// patterns. Everything is bounded: the q stack, form depth, the number of operations and the
/// size of a path; when the operation limit stops a run, <see cref="IsTruncated"/> says so.
/// The interpreter keeps no state between runs except what it caches, but is not thread safe.
/// </summary>
public sealed partial class ContentInterpreter(PdfDocument document)
{
    private const int MaxStack = 256;
    private const int MaxFormDepth = 20;
    private const int MaxSegments = 1_000_000;
    private const int MaxCachedForms = 1024;
    private const long MaxOperations = 10_000_000;
    private const int MaxFormOperations = 1_000_000;
    private const long MaxCachedOperations = 4_000_000;
    private const long MaxFormSize = 64L << 20;

    private static readonly PdfRect Unbounded = new(-1e9, -1e9, 1e9, 1e9);

    private readonly PdfDocument _doc = document;

    internal PdfDocument Document => _doc;
    private readonly Dictionary<PdfStream, IReadOnlyList<ContentOperation>> _formOperations = [];
    private readonly Dictionary<PdfObject, ColorSpaceInfo> _colorSpaces = [];
    private readonly List<PdfStream> _forms = [];
    private readonly List<MarkedContent> _marked = [];
    private readonly List<PdfDictionary?> _resources = [];
    private readonly HashSet<PdfStream> _activeForms = [];
    private readonly HashSet<PdfStream> _walkedPatterns = [];
    private ContentVisitor _visitor = null!;
    private ContentContext _context = null!;
    private GraphicsState _state = null!;
    private List<GraphicsState> _stack = [];
    private int _overflow;
    private int _stackFloor;
    private int _markedFloor;
    private PdfMatrix _base = PdfMatrix.Identity;
    private PdfMatrix _tm = PdfMatrix.Identity;
    private PdfMatrix _tlm = PdfMatrix.Identity;
    private long _budget;
    private long _cachedOperations;
    private PdfFont? _fallbackFont;

    /// <summary>Whether tiling pattern cells are run when something is painted with the pattern.</summary>
    public bool WalkPatterns { get; set; } = true;

    /// <summary>The last run stopped at the operation limit.</summary>
    public bool IsTruncated { get; private set; }

    /// <summary>Runs a page's content, the user space of the page as the starting space and its crop box as the clip.</summary>
    public void Run(PdfPage page, ContentVisitor visitor)
    {
        Begin(visitor, page.CropBox);
        _resources.Add(page.Resources);
        Execute(ContentParser.Parse(page.Contents()));
    }

    /// <summary>Runs a form XObject as if it were painted at the origin of the starting space, with <paramref name="matrix"/> applied first.</summary>
    public void Run(PdfStream form, ContentVisitor visitor, PdfMatrix? matrix = null)
    {
        Begin(visitor, Unbounded);
        _state.Ctm = matrix ?? PdfMatrix.Identity;
        _base = _state.Ctm;
        EnterForm(form, null, null);
    }

    private void Begin(ContentVisitor visitor, PdfRect clip)
    {
        _visitor = visitor;
        _state = new GraphicsState { Clip = clip };
        _context = new ContentContext(_doc, _state, _forms.AsReadOnly(), _marked.AsReadOnly());
        _stack = [];
        _overflow = 0;
        _stackFloor = 0;
        _markedFloor = 0;
        _base = PdfMatrix.Identity;
        _tm = _tlm = PdfMatrix.Identity;
        _budget = MaxOperations;
        IsTruncated = false;
        _forms.Clear();
        _marked.Clear();
        _resources.Clear();
        _activeForms.Clear();
        _walkedPatterns.Clear();
        ResetPath();
    }

    private void Execute(IReadOnlyList<ContentOperation> operations)
    {
        var (markedFloor, stackFloor, overflow) = (_markedFloor, _stackFloor, _overflow);
        _markedFloor = _marked.Count;
        _stackFloor = _stack.Count;
        _overflow = 0;
        for (int i = 0; i < operations.Count; i++)
        {
            if (--_budget < 0)
            {
                IsTruncated = true;
                break;
            }
            _context.OperatorIndex = i;
            _context.Operation = operations[i];
            Dispatch(operations[i]);
        }
        while (_marked.Count > _markedFloor) EndMarkedContent();
        (_markedFloor, _stackFloor, _overflow) = (markedFloor, stackFloor, overflow);
    }

    private void Dispatch(ContentOperation op)
    {
        switch (op.Operator)
        {
            case "q": Push(); break;
            case "Q": Pop(); break;
            case "cm": Concat(op); break;
            case "w": if (Number(op, out double w)) _state.LineWidth = w; break;
            case "J": if (Number(op, out double cap)) _state.LineCap = (int)cap; break;
            case "j": if (Number(op, out double join)) _state.LineJoin = (int)join; break;
            case "M": if (Number(op, out double miter)) _state.MiterLimit = miter; break;
            case "d": SetDash(op); break;
            case "gs": SetExtGState(op); break;

            case "m" or "l" or "c" or "v" or "y" or "h" or "re": BuildPath(op); break;
            case "S" or "s" or "f" or "F" or "f*" or "B" or "B*" or "b" or "b*" or "n": PaintPath(op.Operator); break;
            case "W": _pendingClip = 1; break;
            case "W*": _pendingClip = 2; break;

            case "g" or "G" or "rg" or "RG" or "k" or "K": SetDeviceColor(op); break;
            case "cs" or "CS": SetColorSpace(op); break;
            case "sc" or "scn" or "SC" or "SCN": SetColor(op); break;

            case "BT": _tm = _tlm = PdfMatrix.Identity; SyncText(); break;
            case "Tc": if (Number(op, out double tc)) _state.CharSpacing = tc; break;
            case "Tw": if (Number(op, out double tw)) _state.WordSpacing = tw; break;
            case "Tz": if (Number(op, out double tz)) _state.HorizontalScale = tz / 100; break;
            case "TL": if (Number(op, out double tl)) _state.Leading = tl; break;
            case "Tf": SetFont(op); break;
            case "Tr": if (Number(op, out double tr)) _state.RenderMode = (int)tr; break;
            case "Ts": if (Number(op, out double ts)) _state.Rise = ts; break;
            case "Td" or "TD" or "Tm" or "T*": MoveText(op); break;
            case "Tj" or "TJ" or "'" or "\"": ShowText(op); break;

            case "Do": Paint(op); break;
            case "BI": PaintInlineImage(op); break;
            case "sh": PaintShading(op); break;
            case "BMC" or "BDC": BeginMarkedContent(op); break;
            case "EMC": EndMarkedContent(); break;
        }
    }

    private static bool Number(ContentOperation op, out double value)
    {
        value = 0;
        if (op.Operands.Count == 0 || op.Operands[^1] is not PdfNumber n || !double.IsFinite(n.Value)) return false;
        value = n.Value;
        return true;
    }

    // The last values.Length operands, which all have to be numbers.
    private static bool Numbers(ContentOperation op, Span<double> values)
    {
        int count = op.Operands.Count, n = values.Length;
        if (count < n) return false;
        for (int i = 0; i < n; i++)
        {
            if (op.Operands[count - n + i] is not PdfNumber number || !double.IsFinite(number.Value)) return false;
            values[i] = number.Value;
        }
        return true;
    }

    private void Push()
    {
        if (_stack.Count >= MaxStack)
        {
            _overflow++;
            return;
        }
        _stack.Add(_state.Clone());
    }

    private void Pop()
    {
        if (_overflow > 0)
        {
            _overflow--;
            return;
        }
        if (_stack.Count <= _stackFloor) return;
        _state = _stack[^1];
        _stack.RemoveAt(_stack.Count - 1);
        _context.State = _state;
    }

    private void Concat(ContentOperation op)
    {
        Span<double> m = stackalloc double[6];
        if (Numbers(op, m)) _state.Ctm = new PdfMatrix(m[0], m[1], m[2], m[3], m[4], m[5]).Multiply(_state.Ctm);
    }

    /// <summary>The resource <paramref name="name"/> of a category, looked up in the current resources and then those of the enclosing streams.</summary>
    private PdfObject? FindResource(string category, string name)
    {
        for (int i = _resources.Count - 1; i >= 0; i--)
        {
            if (_doc.Dict(_resources[i], category) is { } entries && entries.ContainsKey(name)) return _doc.Resolve(entries[name]);
        }
        return null;
    }

    private static string? NameOperand(ContentOperation op) => op.Operands.Count > 0 && op.Operands[0] is PdfName n ? n.Value : null;
}
