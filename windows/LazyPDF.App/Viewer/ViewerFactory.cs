namespace LazyPDF.App.Viewer;

/// <summary>Makes the viewer the stage holds.</summary>
public static class ViewerFactory
{
    public static IDocumentViewer Create() => new PageViewer();
}
