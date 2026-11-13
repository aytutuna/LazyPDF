namespace LazyPDF.Core;

// The rule checks behind PdfAValidator. Clause numbers are given for part 1 and for parts 2 and 3;
// part 4 follows the numbering of part 2.
internal sealed partial class PdfAChecker(PdfDocument document, PdfALevel level)
{
    private const int MaxIssues = 1000;

    private readonly PdfDocument _doc = document;
    private readonly List<PdfAIssue> _issues = [];
    private readonly HashSet<string> _seen = [];
    private bool _truncated;

    private int Part => level.Part();
    private bool IsPart1 => Part == 1;

    /// <summary>The fonts met, each with the codes (CIDs for a composite font) shown with it.</summary>
    internal Dictionary<PdfDictionary, SortedSet<int>> FontUses { get; } = new(ReferenceEqualityComparer.Instance);

    public PdfAReport Report() => new(level, _issues, _truncated);

    public void Run()
    {
        CheckFile();
        CheckCatalog();
        CheckPages();
        CheckObjects();
        CheckFonts();
        CheckStructure();
    }

    /// <summary>The clause for part 1, or for the later parts.</summary>
    private string C(string part1, string later) => IsPart1 ? part1 : later;

    private void Add(string clause, string where, string message)
    {
        if (_issues.Count >= MaxIssues)
        {
            _truncated = true;
            return;
        }
        if (_seen.Add($"{clause}|{where}|{message}")) _issues.Add(new PdfAIssue(clause, where, message));
    }

    private IReadOnlyList<string> FilterNames(PdfDictionary dictionary, string key = "Filter") =>
        _doc.Resolve(dictionary[key]) switch
        {
            PdfName name => [name.Value],
            PdfArray array => [.. array.Items.Take(32).Select(i => (_doc.Resolve(i) as PdfName)?.Value ?? "")],
            _ => [],
        };

    private static bool IsFilter(string name, string full, string abbreviation) => name == full || name == abbreviation;
}
