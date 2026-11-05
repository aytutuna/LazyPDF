using LazyPDF.Core;

namespace LazyPDF.App.Tools.Optimize;

/// <summary>One line of "where the space goes": a kind of data, its bytes and its share of the file.</summary>
public sealed record AuditRow(SpaceKind Kind, long Bytes, double Share)
{
    public string Name => OptimizeText.KindName(Kind);

    public string Size => SizeText.Of(Bytes);

    public string Summary => Loc.T("{0}, {1}", Name, Size);

    /// <summary>The kinds that hold any bytes, the biggest first.</summary>
    public static IReadOnlyList<AuditRow> Of(SpaceAudit audit) =>
        [.. audit.Bytes.Where(b => b.Value > 0)
            .OrderByDescending(b => b.Value)
            .Select(b => new AuditRow(b.Key, b.Value, audit.FileSize > 0 ? (double)b.Value / audit.FileSize : 0))];
}
