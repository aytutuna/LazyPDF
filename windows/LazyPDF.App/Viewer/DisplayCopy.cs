using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>
/// A copy of a file with some layers switched, and a renderer loaded from it. The viewer draws from this while the
/// layers differ from the file; the file itself, and the tab's session, are not touched.
/// </summary>
internal sealed record DisplayCopy(PdfEditSession Session, WindowsPageRenderer Renderer)
{
    /// <summary>Null when the engine or the system cannot read the copy.</summary>
    public static DisplayCopy? Create(byte[] bytes, string? password, IEnumerable<KeyValuePair<PdfReference, bool>> changes, X509Certificate2? certificate = null)
    {
        try
        {
            var session = certificate is null ? PdfEditSession.Open(bytes, password) : PdfEditSession.Open(bytes, certificate);
            foreach (var (layer, visible) in changes) PdfLayers.SetVisible(session.Document, layer, visible);
            // Windows hides a layer by its usage rules (/AS) whatever /ON and /OFF say; in the copy the switches decide.
            var document = session.Document;
            if (document.Dict(document.Catalog, "OCProperties") is { } properties && document.Dict(properties, "D") is { } config) config.Remove("AS");
            session.Commit("Layers");
            var renderer = new WindowsPageRenderer();
            if (renderer.Load(session, password)) return new DisplayCopy(session, renderer);
            renderer.Dispose();
            return null;
        }
        catch (PdfReadException)
        {
            return null;
        }
    }
}
