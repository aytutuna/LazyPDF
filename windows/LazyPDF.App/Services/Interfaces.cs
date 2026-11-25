using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>Draws the pages of one open document. A tab holds one and loads it again after every change to the file.</summary>
public interface IDocumentRenderer : IPageRenderer, IDisposable
{
    /// <summary>
    /// Reads the file as the session holds it now. False when the system cannot draw it: the
    /// document can still be edited, and <see cref="IPageRenderer.Render"/> gives null.
    /// </summary>
    bool Load(PdfEditSession session, string? password);

    /// <summary>As <see cref="Load"/>, without holding the calling thread where the renderer can avoid it.</summary>
    Task<bool> LoadAsync(PdfEditSession session, string? password) => Task.FromResult(Load(session, password));

    /// <summary>Width and height in points of page <paramref name="pageIndex"/> as displayed (crop box, /Rotate applied).</summary>
    (double Width, double Height) PageSize(int pageIndex);
}

/// <summary>The other Lazy apps on this computer: Lazy Scan to scan into, Lazy Print to print with.</summary>
public interface ISisterApps
{
    bool LazyScanInstalled { get; }

    bool LazyPrintInstalled { get; }

    /// <summary>Raised from a background thread when a refreshed answer differs from the one given before.</summary>
    event EventHandler? Changed { add { } remove { } }

    bool OpenLazyScan();

    /// <summary>Hands the file to Lazy Print. False when it is not there to take it.</summary>
    bool TryPrint(string path);
}
