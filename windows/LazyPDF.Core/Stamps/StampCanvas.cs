namespace LazyPDF.Core;

/// <summary>
/// Content for one page drawn in the page as it is shown: y up, origin at the bottom-left of the
/// crop box, rotation and /UserUnit already undone by one <c>cm</c>. Text drawn here is upright
/// on a rotated page.
/// </summary>
internal sealed class StampCanvas
{
    private readonly int _id;
    private readonly bool _inLayer;

    public StampCanvas(PdfPage page, int id, bool inLayer)
    {
        var geometry = new PageGeometry(page);
        Width = geometry.Width;
        Height = geometry.Height;
        _id = id;
        _inLayer = inLayer;
        var (ox, oy) = geometry.ToUser(0, 0);
        var (xx, xy) = geometry.ToUser(1, 0);
        var (yx, yy) = geometry.ToUser(0, 1);
        var flip = new PdfMatrix(1, 0, 0, -1, 0, Height);
        Writer.Save().Concat(flip.Multiply(new PdfMatrix(xx - ox, xy - oy, yx - ox, yy - oy, ox, oy)));
    }

    /// <summary>The page as shown, in points.</summary>
    public double Width { get; }
    public double Height { get; }
    public ContentWriter Writer { get; } = new();

    /// <summary>Opens an artifact (ISO 32000-1 14.8.2.2) carrying the run's id, inside the optional content group if there is one.</summary>
    public void BeginArtifact(string type, string? subtype, PdfRect? bounds = null)
    {
        var properties = new PdfDictionary();
        properties["Type"] = new PdfName(type);
        if (subtype is not null) properties["Subtype"] = new PdfName(subtype);
        if (bounds is { } box) properties["BBox"] = box.ToArray();
        properties[StampStreams.Key] = new PdfNumber(_id);
        Writer.Op("BDC", [new PdfName("Artifact"), properties]);
        if (_inLayer) Writer.Op("BDC", [new PdfName("OC"), new PdfName(StampStreams.LayerResourceName(_id))]);
    }

    public void EndArtifact()
    {
        if (_inLayer) Writer.EndMarked();
        Writer.EndMarked();
    }

    public byte[] ToArray() => Writer.Restore().ToArray();

    /// <summary>Rotation by <paramref name="degrees"/> counter-clockwise about the centre of a box, as the matrix that takes the box's own space (origin bottom-left) to the page.</summary>
    public static PdfMatrix Place(double x, double y, double width, double height, double degrees)
    {
        double a = degrees * Math.PI / 180;
        double cos = Math.Cos(a), sin = Math.Sin(a);
        return PdfMatrix.Translate(-width / 2, -height / 2)
            .Multiply(new PdfMatrix(cos, sin, -sin, cos, 0, 0))
            .Multiply(PdfMatrix.Translate(x + width / 2, y + height / 2));
    }
}
