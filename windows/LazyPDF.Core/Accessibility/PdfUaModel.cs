namespace LazyPDF.Core;

/// <summary>
/// One failure condition the file hits. <paramref name="Condition"/> is the Matterhorn Protocol id ("06-002", whose first
/// two digits are the checkpoint) and <paramref name="Clause"/> the clause of ISO 14289-1 behind it.
/// </summary>
public sealed record PdfUaIssue(string Condition, string Clause, string Where, string Message)
{
    public string Checkpoint => Condition[..2];
}

/// <summary>What the PDF/UA-1 check found. <see cref="Truncated"/> is set when it stopped listing at the cap.</summary>
public sealed record PdfUaReport(IReadOnlyList<PdfUaIssue> Issues, bool Truncated)
{
    public bool IsValid => Issues.Count == 0;
}

