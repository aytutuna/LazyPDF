namespace LazyPDF.Core;

/// <summary>Texts the pages tools show, kept in one place until they go through Loc.T.</summary>
public static class PagesText
{
    public const string RangeUsage = "Type pages like 1-3, 5";

    public static string PastTheEnd(int page, int count) =>
        $"Page {page} is past the end ({count} page{(count == 1 ? "" : "s")})";
}
