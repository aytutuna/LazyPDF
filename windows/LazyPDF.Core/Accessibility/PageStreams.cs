namespace LazyPDF.Core;

/// <summary>
/// A page's content streams parsed one by one, with operations numbered across them as the interpreter
/// numbers the page's joined content. Null from <see cref="Load"/> when a stream does not parse or an
/// operator stands in another stream than its operands, where one stream's operations cannot be cut alone.
/// </summary>
internal sealed class PageStreams
{
    private static readonly HashSet<string> Content = ["Tj", "TJ", "'", "\"", "Do", "BI"];

    private readonly PdfDocument _document;
    private readonly List<int> _first = [];

    private PageStreams(PdfDocument document, PdfPage page)
    {
        _document = document;
        Page = page;
    }

    public PdfPage Page { get; }
    public List<PdfStream> Streams { get; } = [];
    public List<byte[]> Data { get; } = [];
    public List<IReadOnlyList<ContentOperation>> Parsed { get; } = [];

    /// <summary>Another page draws one of these streams, so rewriting it would change that page too.</summary>
    public bool IsShared { get; private set; }

    public int Count { get; private set; }

    public static PageStreams? Load(PdfDocument document, PdfPage page)
    {
        var result = new PageStreams(document, page);
        try
        {
            foreach (var stream in TagSession.Streams(document, page))
            {
                result.Streams.Add(stream);
                result.Data.Add(document.Data(stream));
                result._first.Add(result.Count);
                result.Parsed.Add(ContentParser.Parse(result.Data[^1]));
                result.Count += result.Parsed[^1].Count;
            }
            var joined = ContentParser.Parse(page.Contents());
            if (!result.Parsed.SelectMany(p => p).Select(o => (o.Operator, o.Operands.Count)).SequenceEqual(joined.Select(o => (o.Operator, o.Operands.Count)))) return null;
        }
        catch (PdfReadException)
        {
            return null;
        }
        var uses = TagSession.SharedStreams(document);
        result.IsShared = result.Streams.Any(s => uses.GetValueOrDefault(s) > 1);
        return result;
    }

    public static bool IsContent(ContentOperation op) => Content.Contains(op.Operator);

    public (int Stream, ContentOperation Operation) At(int global)
    {
        int stream = _first.Count - 1;
        while (_first[stream] > global) stream--;
        return (stream, Parsed[stream][global - _first[stream]]);
    }

    public Func<string, PdfDictionary?> Properties()
    {
        var properties = _document.Dict(Page.Resources, "Properties");
        return name => _document.Dict(properties, name);
    }

    public List<ContentInsertion>[] NewEdits() => [.. Streams.Select(_ => new List<ContentInsertion>())];

    public void Save(List<ContentInsertion>[] edits)
    {
        for (int s = 0; s < Streams.Count; s++)
        {
            if (edits[s].Count == 0) continue;
            Streams[s].Data = PdfFilterEncoders.Flate(ContentTagger.Apply(Data[s], edits[s]));
            Streams[s].Dictionary["Filter"] = new PdfName("FlateDecode");
            Streams[s].Dictionary.Remove("DecodeParms");
        }
    }
}

/// <summary>A marked-content sequence of a page, BMC or BDC to its EMC, with the content operations directly inside it.</summary>
internal sealed class MarkedSequence
{
    /// <summary>Operation number of the BMC or BDC; -1 for the pseudo sequence that holds the page level.</summary>
    public int Begin { get; init; } = -1;

    public int? Mcid { get; init; }
    public bool Artifact { get; init; }
    public MarkedSequence? Parent { get; init; }
    public List<int> Content { get; } = [];
    public List<MarkedSequence> Children { get; } = [];

    /// <summary>A sequence that already says what its content is.</summary>
    public bool IsClaimed => Mcid is not null || Artifact;

    public IEnumerable<MarkedSequence> Descendants()
    {
        foreach (var child in Children)
        {
            yield return child;
            foreach (var deeper in child.Descendants()) yield return deeper;
        }
    }

    /// <summary>Every content operation inside, nested sequences included.</summary>
    public IEnumerable<int> AllContent() => Content.Concat(Children.SelectMany(c => c.AllContent()));

    /// <summary>The sequences of the page and, in the returned pseudo sequence, what sits outside all of them. An EMC with nothing open is dropped and a BDC never closed runs to the end.</summary>
    public static MarkedSequence Scan(PageStreams page, PdfDocument document)
    {
        var properties = page.Properties();
        var top = new MarkedSequence();
        var current = top;
        var open = new Stack<MarkedSequence>();
        int global = 0;
        foreach (var operations in page.Parsed)
        {
            foreach (var op in operations)
            {
                if (op.Operator is "BMC" or "BDC")
                {
                    int? mcid = null;
                    if (op.Operator == "BDC" && op.Operands.Count > 1)
                    {
                        var dictionary = op.Operands[1] switch { PdfDictionary d => d, PdfName n => properties(n.Value), _ => null };
                        if (dictionary is not null && document.Integer(dictionary, "MCID") is { } id and >= 0 and <= int.MaxValue) mcid = (int)id;
                    }
                    var sequence = new MarkedSequence
                    {
                        Begin = global, Mcid = mcid, Parent = current,
                        Artifact = op.Operands.Count > 0 && op.Operands[0] is PdfName { Value: "Artifact" },
                    };
                    current.Children.Add(sequence);
                    open.Push(current);
                    current = sequence;
                }
                else if (op.Operator == "EMC")
                {
                    if (open.Count > 0) current = open.Pop();
                }
                else if (PageStreams.IsContent(op))
                {
                    current.Content.Add(global);
                }
                global++;
            }
        }
        return top;
    }
}
