namespace LazyPDF.Core;

/// <summary>Text to put into a content stream at a byte position. At one position the order decides: closings (0) before openings (1).</summary>
internal readonly record struct ContentInsertion(int Position, int Order, string Text);

/// <summary>
/// Plans the marked-content sequences of one page (ISO 32000-1 14.6). Text, images and forms go to
/// the node that claimed them with an /MCID; paths, shadings and anything unclaimed become
/// /Artifact. Operations are joined into one sequence only while nothing that would have to nest
/// differently (a text object, a graphics state, other marked content) lies between them, so the
/// result is well nested whatever the page does.
/// </summary>
internal sealed class ContentTagger
{
    private static readonly HashSet<string> Shows = ["Tj", "TJ", "'", "\""];
    private static readonly HashSet<string> Paths = ["m", "l", "c", "v", "y", "re", "h", "W", "W*", "f", "F", "f*", "B", "B*", "b", "b*", "S", "s", "n"];
    private static readonly HashSet<string> Breaks = ["BT", "ET", "q", "Q", "cm", "d0", "d1"];
    private static readonly HashSet<string> Singles = ["Do", "BI", "sh"];

    private readonly IReadOnlyList<IReadOnlyList<ContentOperation>> _streams;
    private readonly IReadOnlyDictionary<int, TagNode> _claims;
    private readonly Func<string, PdfDictionary?> _properties;
    private readonly Func<TagNode, int> _newMcid;
    private readonly Stack<bool> _open = [];
    private int _skip;
    private bool _running;
    private TagNode? _target;
    private int _stream, _first, _last;

    public ContentTagger(
        IReadOnlyList<IReadOnlyList<ContentOperation>> streams, IReadOnlyDictionary<int, TagNode> claims,
        Func<string, PdfDictionary?> properties, Func<TagNode, int> newMcid)
    {
        _streams = streams;
        _claims = claims;
        _properties = properties;
        _newMcid = newMcid;
        Insertions = [.. streams.Select(_ => new List<ContentInsertion>())];
    }

    /// <summary>Per stream, what to insert.</summary>
    public List<ContentInsertion>[] Insertions { get; }

    public int Artifacts { get; private set; }

    public void Run()
    {
        int global = 0;
        for (int s = 0; s < _streams.Count; s++)
        {
            Close();
            for (int i = 0; i < _streams[s].Count; i++) Handle(s, i, global++);
        }
        Close();
    }

    private void Handle(int stream, int index, int global)
    {
        var op = _streams[stream][index];
        string name = op.Operator;
        if (name is "BMC" or "BDC")
        {
            Close();
            bool foreign = IsForeign(op);
            _open.Push(foreign);
            if (foreign) _skip++;
        }
        else if (name == "EMC")
        {
            Close();
            if (_open.Count > 0 && _open.Pop()) _skip--;
        }
        else if (Breaks.Contains(name))
        {
            Close();
        }
        else if (_skip > 0)
        {
            return;
        }
        else if (Shows.Contains(name))
        {
            Extend(stream, index, _claims.GetValueOrDefault(global));
        }
        else if (Paths.Contains(name))
        {
            Extend(stream, index, null);
        }
        else if (Singles.Contains(name))
        {
            Close();
            Extend(stream, index, _claims.GetValueOrDefault(global));
            Close();
        }
    }

    // Content already inside an /Artifact or a sequence with an /MCID is somebody else's to describe.
    private bool IsForeign(ContentOperation op)
    {
        if (op.Operands.Count == 0 || op.Operands[0] is not PdfName tag) return false;
        if (tag.Value == "Artifact") return true;
        var properties = op.Operands.Count > 1 ? op.Operands[1] switch
        {
            PdfDictionary d => d,
            PdfName n => _properties(n.Value),
            _ => null,
        } : null;
        return properties?.ContainsKey("MCID") == true;
    }

    private void Extend(int stream, int index, TagNode? target)
    {
        if (_running && _stream == stream && ReferenceEquals(_target, target))
        {
            _last = index;
            return;
        }
        Close();
        (_running, _target, _stream, _first, _last) = (true, target, stream, index, index);
    }

    private void Close()
    {
        if (!_running) return;
        _running = false;
        var operations = _streams[_stream];
        string begin;
        if (_target is null)
        {
            begin = "/Artifact BMC ";
            Artifacts++;
        }
        else
        {
            begin = $"/{_target.Type} <</MCID {_newMcid(_target)}>> BDC ";
        }
        Insertions[_stream].Add(new ContentInsertion(operations[_first].Start, 1, begin));
        Insertions[_stream].Add(new ContentInsertion(operations[_last].End, 0, " EMC"));
    }

    public static byte[] Apply(byte[] data, List<ContentInsertion> insertions)
    {
        var ordered = insertions.OrderBy(i => i.Position).ThenBy(i => i.Order).ToList();
        using var output = new MemoryStream(data.Length + insertions.Count * 24);
        int at = 0;
        foreach (var insertion in ordered)
        {
            int position = Math.Clamp(insertion.Position, at, data.Length);
            output.Write(data, at, position - at);
            output.Write(System.Text.Encoding.ASCII.GetBytes(insertion.Text));
            at = position;
        }
        output.Write(data, at, data.Length - at);
        return output.ToArray();
    }
}
