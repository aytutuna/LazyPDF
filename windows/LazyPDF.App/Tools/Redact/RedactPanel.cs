namespace LazyPDF.App.Tools.Redact;

public sealed class RedactPanel : ToolPanel
{
    public RedactPanel() => Content = new StubNote("redact");
}
