namespace LazyPDF.Core;

[Flags]
internal enum StateParts
{
    None = 0,
    Font = 1,
    CharSpacing = 2,
    WordSpacing = 4,
    Scale = 8,
    Leading = 16,
    Mode = 32,
    Rise = 64,
    Fill = 128,
    Stroke = 256,
    States = 512,
    Text = Font | CharSpacing | WordSpacing | Scale | Leading | Mode | Rise,
    All = Text | Fill | Stroke | States,
}

/// <summary>
/// The operators that set the graphics state in force before one operation of a content stream,
/// kept as the operations themselves so that an edit can write them back to restore what it
/// changed. Instances are never changed after the scan.
/// </summary>
internal sealed class OpState
{
    private static readonly IReadOnlyList<ContentOperation> None = [];

    public ContentOperation? Font, CharSpacing, WordSpacing, Scale, Leading, Mode, Rise;
    public IReadOnlyList<ContentOperation> Fill = None, Stroke = None, States = None;
    public PdfMatrix Ctm = PdfMatrix.Identity;

    /// <summary>Open <c>q</c> count, those past the interpreter's stack included.</summary>
    public int Depth;
    public bool InText;

    public OpState With(Action<OpState> change)
    {
        var copy = (OpState)MemberwiseClone();
        change(copy);
        return copy;
    }

    /// <summary>Writes the operators that bring a state back to this one for the chosen parts; a part never set is written as its default.</summary>
    public void Replay(ContentWriter w, StateParts parts)
    {
        if (parts.HasFlag(StateParts.Font) && Font is not null) w.Add(Font);
        Put(w, parts, StateParts.CharSpacing, CharSpacing, "Tc", 0);
        Put(w, parts, StateParts.WordSpacing, WordSpacing, "Tw", 0);
        Put(w, parts, StateParts.Scale, Scale, "Tz", 100);
        Put(w, parts, StateParts.Leading, Leading, "TL", 0);
        Put(w, parts, StateParts.Mode, Mode, "Tr", 0);
        Put(w, parts, StateParts.Rise, Rise, "Ts", 0);
        if (parts.HasFlag(StateParts.Fill)) PutColor(w, Fill, "g");
        if (parts.HasFlag(StateParts.Stroke)) PutColor(w, Stroke, "G");
        if (parts.HasFlag(StateParts.States)) foreach (var gs in States) w.Add(gs);
    }

    private static void Put(ContentWriter w, StateParts parts, StateParts part, ContentOperation? op, string name, double fallback)
    {
        if (!parts.HasFlag(part)) return;
        if (op is not null) w.Add(op);
        else w.Op(name, fallback);
    }

    private static void PutColor(ContentWriter w, IReadOnlyList<ContentOperation> ops, string gray)
    {
        if (ops.Count == 0) w.Op(gray, 0);
        foreach (var op in ops) w.Add(op);
    }
}

/// <summary>The scan of a content stream: the state before each operation, and after the last.</summary>
internal sealed class OpStates
{
    private const int MaxStack = 256;

    private OpStates(OpState[] before, OpState end, PdfMatrix baseCtm)
    {
        Before = before;
        End = end;
        BaseCtm = baseCtm;
    }

    public OpState[] Before { get; }
    public OpState End { get; }

    /// <summary>The matrix in force once every open <c>q</c> has been closed.</summary>
    public PdfMatrix BaseCtm { get; }

    /// <summary>The state before operation <paramref name="index"/>; the end state for an index past the last.</summary>
    public OpState At(int index) => index < Before.Length ? Before[index] : End;

    /// <summary>Follows the stack the way the interpreter does: a <c>Q</c> with nothing to pop is ignored.</summary>
    public static OpStates Scan(IReadOnlyList<ContentOperation> ops)
    {
        var before = new OpState[ops.Count];
        var current = new OpState();
        var stack = new List<OpState>();
        int overflow = 0;
        for (int i = 0; i < ops.Count; i++)
        {
            before[i] = current;
            var op = ops[i];
            switch (op.Operator)
            {
                case "q":
                    if (stack.Count >= MaxStack) overflow++;
                    else stack.Add(current);
                    current = current.With(s => s.Depth = stack.Count + overflow);
                    break;
                case "Q":
                    if (overflow > 0) overflow--;
                    else if (stack.Count > 0)
                    {
                        bool inText = current.InText;
                        current = stack[^1].With(s => s.InText = inText);
                        stack.RemoveAt(stack.Count - 1);
                    }
                    current = current.With(s => s.Depth = stack.Count + overflow);
                    break;
                case "cm":
                    if (Matrix(op) is { } m) current = current.With(s => s.Ctm = m.Multiply(s.Ctm));
                    break;
                case "BT": current = current.With(s => s.InText = true); break;
                case "ET": current = current.With(s => s.InText = false); break;
                case "Tf": current = current.With(s => s.Font = op); break;
                case "Tc": current = current.With(s => s.CharSpacing = op); break;
                case "Tw": current = current.With(s => s.WordSpacing = op); break;
                case "Tz": current = current.With(s => s.Scale = op); break;
                case "TL": current = current.With(s => s.Leading = op); break;
                case "Tr": current = current.With(s => s.Mode = op); break;
                case "Ts": current = current.With(s => s.Rise = op); break;
                case "g" or "rg" or "k" or "cs": current = current.With(s => s.Fill = [op]); break;
                case "G" or "RG" or "K" or "CS": current = current.With(s => s.Stroke = [op]); break;
                case "sc" or "scn": current = current.With(s => s.Fill = Colored(s.Fill, op)); break;
                case "SC" or "SCN": current = current.With(s => s.Stroke = Colored(s.Stroke, op)); break;
                case "gs": current = current.With(s => s.States = [.. s.States.TakeLast(15), op]); break;
            }
        }
        return new OpStates(before, current, stack.Count > 0 ? stack[0].Ctm : current.Ctm);
    }

    // A colour operator after its space operator replays together with it.
    private static IReadOnlyList<ContentOperation> Colored(IReadOnlyList<ContentOperation> ops, ContentOperation op) =>
        ops.Count > 0 ? [ops[0], op] : [op];

    private static PdfMatrix? Matrix(ContentOperation op)
    {
        if (op.Operands.Count < 6) return null;
        Span<double> n = stackalloc double[6];
        for (int i = 0; i < 6; i++)
        {
            if (op.Operands[op.Operands.Count - 6 + i] is not PdfNumber { Value: var v } || !double.IsFinite(v)) return null;
            n[i] = v;
        }
        return new PdfMatrix(n[0], n[1], n[2], n[3], n[4], n[5]);
    }
}
