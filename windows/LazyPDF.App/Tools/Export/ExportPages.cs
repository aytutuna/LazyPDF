using LazyPDF.Core;

namespace LazyPDF.App.Tools.Export;

public enum PageScope
{
    All,
    Current,
    Typed,
}

/// <summary>The pages an export covers: null for all of them, or what is wrong with the pages typed.</summary>
public sealed record ExportPages(IReadOnlyList<int>? Pages, string? Error)
{
    public static ExportPages Of(PageScope scope, string typed, int current, int count)
    {
        if (scope == PageScope.All) return new(null, null);
        if (scope == PageScope.Current) return new([current], null);
        var parsed = PageRange.Parse(typed, count);
        return parsed.IsSuccess ? new([.. parsed.Pages.Distinct()], null) : new(null, parsed.Error!.Message);
    }
}
