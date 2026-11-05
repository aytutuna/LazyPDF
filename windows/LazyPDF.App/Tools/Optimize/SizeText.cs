namespace LazyPDF.App.Tools.Optimize;

internal static class SizeText
{
    public static string Of(long bytes) => bytes switch
    {
        < 1024 => Loc.T("{0} bytes", bytes),
        < 1024 * 1024 => Loc.T("{0} KB", Math.Round(bytes / 1024.0, 1)),
        _ => Loc.T("{0} MB", Math.Round(bytes / 1048576.0, 1)),
    };

    public static int Percent(long before, long after) =>
        before <= 0 ? 0 : (int)Math.Round(100.0 * (before - after) / before);
}
