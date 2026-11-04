namespace LazyPDF.Core;

/// <summary>Texts the pages tools show.</summary>
public static class PagesText
{
    public static string RangeUsage => Loc.T("Type pages like 1-3, 5");

    public static string PastTheEnd(int page, int count) =>
        Loc.Plural(count, "Page {1} is past the end ({0} page)", "Page {1} is past the end ({0} pages)", page);
}
