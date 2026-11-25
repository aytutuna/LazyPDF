namespace LazyPDF.Core;

/// <summary>
/// One failure condition the file hits. <paramref name="Condition"/> is the Matterhorn Protocol id ("06-002", whose first
/// two digits are the checkpoint), empty when the protocol has no condition for the finding, and <paramref name="Clause"/>
/// the clause of ISO 14289-1 behind it.
/// </summary>
public sealed record PdfUaIssue(string Condition, string Clause, string Where, string Message)
{
    public string Checkpoint => Condition.Length < 2 ? "" : Condition[..2];
}

/// <summary>What the PDF/UA-1 check found. <see cref="Truncated"/> is set when it stopped listing at the cap.</summary>
public sealed record PdfUaReport(IReadOnlyList<PdfUaIssue> Issues, bool Truncated)
{
    public bool IsValid => Issues.Count == 0;
}


/// <param name="Marked">The file now names PDF/UA-1; false leaves it as it was.</param>
/// <param name="Blocking">The issues that stood in the way, empty when marked. Those the marking itself would have settled are not in it.</param>
public sealed record PdfUaMarkResult(bool Marked, PdfUaReport Blocking);
