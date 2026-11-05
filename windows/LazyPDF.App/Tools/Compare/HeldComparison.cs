namespace LazyPDF.App.Tools.Compare;

/// <summary>A finished comparison, kept for the tab it was run on so that switching tabs or writing the report does not lose it.</summary>
/// <param name="Revision">The state of the open file the rows refer to.</param>
internal sealed class HeldComparison(CompareSession session, string? path, bool openIsNew, int revision) : IDisposable
{
    public CompareSession Session { get; } = session;

    public string? Path { get; } = path;

    public bool OpenIsNew { get; } = openIsNew;

    public int Revision { get; } = revision;

    public CompareWindow? Window { get; set; }

    public void Dispose()
    {
        Window?.Close();
        Session.Dispose();
    }
}
