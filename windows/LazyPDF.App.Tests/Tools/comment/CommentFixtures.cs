using System.Reflection;
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tests.Tools.Comment;

/// <summary>A document with a tab of its own, and a marker over it.</summary>
internal sealed class CommentFixture : IDisposable
{
    public CommentFixture(int pages = 1)
    {
        Tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(pages)), new FakeRenderer(), null, "a.pdf");
    }

    public DocumentTab Tab { get; }

    public PdfDocument Document => Tab.Document;

    public Marker Marker => new(Tab.Document, new FakeFonts(), "Ana", new DateTimeOffset(2026, 11, 4, 10, 0, 0, TimeSpan.Zero));

    public PageGeometry Geometry => new(Document.Pages[0]);

    public IReadOnlyList<PdfAnnotation> Marks(int page = 0) => PdfAnnotations.Read(Document, Document.Pages[page]);

    public void Dispose() => Tab.Dispose();
}

/// <summary>Stands in for the viewer where a pointer tool only needs the overlay of a page and the zoom.</summary>
internal class ViewerStandIn : DispatchProxy
{
    public Dictionary<int, PageOverlay> Overlays { get; } = [];

    public double Zoom { get; set; } = 1;

    public static IDocumentViewer Create(out ViewerStandIn stand)
    {
        var viewer = Create<IDocumentViewer, ViewerStandIn>();
        stand = (ViewerStandIn)(object)viewer;
        return viewer;
    }

    protected override object? Invoke(MethodInfo? method, object?[]? args)
    {
        switch (method!.Name)
        {
            case "Overlay":
                int page = (int)args![0]!;
                if (!Overlays.TryGetValue(page, out var overlay)) Overlays[page] = overlay = new PageOverlay(page, new Size(595, 842));
                return overlay;
            case "PageSize":
                return new Size(595, 842);
            case "PageToView":
                return null;
            case "get_Zoom":
                return Zoom;
            default:
                throw new NotSupportedException(method.Name);
        }
    }
}
