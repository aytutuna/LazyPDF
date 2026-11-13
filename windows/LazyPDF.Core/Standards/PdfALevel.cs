namespace LazyPDF.Core;

/// <summary>
/// A PDF/A part and conformance level (ISO 19005). Part 4 has no level A, B or U; the plain "4" is meant. The level A values
/// come last because a saved batch holds the numbers.
/// </summary>
public enum PdfALevel
{
    A1b,
    A2b,
    A2u,
    A3b,
    A3u,
    A4,
    A1a,
    A2a,
    A3a,
}

public static class PdfALevels
{
    public static int Part(this PdfALevel level) => level switch
    {
        PdfALevel.A1a or PdfALevel.A1b => 1,
        PdfALevel.A2a or PdfALevel.A2b or PdfALevel.A2u => 2,
        PdfALevel.A3a or PdfALevel.A3b or PdfALevel.A3u => 3,
        _ => 4,
    };

    /// <summary>"A", "B" or "U"; null for part 4, which has none.</summary>
    public static string? Conformance(this PdfALevel level) => level switch
    {
        PdfALevel.A1a or PdfALevel.A2a or PdfALevel.A3a => "A",
        PdfALevel.A1b or PdfALevel.A2b or PdfALevel.A3b => "B",
        PdfALevel.A2u or PdfALevel.A3u => "U",
        _ => null,
    };

    /// <summary>The level asks for Unicode text mappings (levels A and U).</summary>
    public static bool NeedsUnicode(this PdfALevel level) => level is PdfALevel.A1a or PdfALevel.A2a or PdfALevel.A3a or PdfALevel.A2u or PdfALevel.A3u;

    /// <summary>The level asks for a tagged file (level A).</summary>
    public static bool NeedsTags(this PdfALevel level) => level.Conformance() == "A";

    public static string Name(this PdfALevel level) => level == PdfALevel.A4 ? "PDF/A-4" : $"PDF/A-{level.Part()}{level.Conformance()!.ToLowerInvariant()}";
}

/// <summary>One rule a file breaks: the clause of the standard, where in the file, and what is wrong in a sentence.</summary>
public sealed record PdfAIssue(string Clause, string Where, string Message);

/// <summary>What the validator found. <see cref="Truncated"/> is set when it stopped listing at the cap.</summary>
public sealed record PdfAReport(PdfALevel Level, IReadOnlyList<PdfAIssue> Issues, bool Truncated)
{
    public bool IsValid => Issues.Count == 0;
}

/// <summary>
/// Checks a document against PDF/A (ISO 19005) rule by rule. It reads the file as the reader sees
/// it, so a file the reader had to repair is reported for the repair.
/// </summary>
public static class PdfAValidator
{
    public static PdfAReport Validate(PdfDocument document, PdfALevel level)
    {
        var checker = new PdfAChecker(document, level);
        checker.Run();
        return checker.Report();
    }
}
