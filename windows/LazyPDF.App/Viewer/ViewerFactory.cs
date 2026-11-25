using LazyPDF.App.Services;

namespace LazyPDF.App.Viewer;

/// <summary>Makes the viewer the stage holds.</summary>
public static class ViewerFactory
{
    public static IDocumentViewer Create(bool remembersView = true) =>
        new PageViewer(remembersView ? StoreFiles.DefaultDirectory : null);
}
