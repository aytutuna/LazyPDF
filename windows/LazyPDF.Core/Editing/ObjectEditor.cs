using System.Text;

namespace LazyPDF.Core;

public enum OrderMove
{
    Forward,
    Backward,
    Front,
    Back,
}

/// <summary>Changes to images and paths and the movement of any object, gathered into an <see cref="EditBatch"/>.</summary>
internal sealed partial class ObjectEditor(PageModel model, EditBatch batch, TextEditor text)
{
    private PdfDocument Document => model.Document;

    public int Changed { get; private set; }
    public List<SkippedObject> Skipped { get; } = [];

    // An object that cannot be changed is reported and leaves nothing behind in the batch.
    public void Try(PageObject o, Action change)
    {
        var mark = batch.Save();
        try
        {
            change();
            Changed++;
        }
        catch (EditConflictException e)
        {
            batch.Restore(mark);
            Skipped.Add(new SkippedObject(o.Id, e.Message));
        }
    }

    private static Place PlaceOf(PageObject o) => new(o.Unit, o.Visit);

    private static byte[] Bytes(string text) => Encoding.Latin1.GetBytes(text);

    private static string Matrix(PdfMatrix m) => Encoding.Latin1.GetString(new ContentWriter().Concat(m).ToArray());

    private void Insert(Place place, int at, string text)
    {
        if (!batch.Insert(place, at, Bytes(text))) throw new EditConflictException(EditingText.SharedForm);
    }

    private void Replace(Place place, int start, int end, string text)
    {
        if (!batch.Replace(place, start, end, Bytes(text))) throw new EditConflictException(EditingText.SharedForm);
    }

    /// <summary>Puts <paramref name="before"/> in front of operation <paramref name="first"/> and <paramref name="after"/> behind operation <paramref name="last"/>.</summary>
    private void Wrap(Place place, int first, int last, string before, string after)
    {
        var ops = place.Unit.Operations;
        Insert(place, ops[first].Start, before);
        Insert(place, ops[last].End, after);
    }

    /// <summary>The matrix that applies <paramref name="t"/> (in user space) at a point of a stream where <paramref name="ctm"/> is in force: ctm t ctm^-1.</summary>
    private static PdfMatrix Around(PdfMatrix ctm, PdfMatrix t)
    {
        var inverse = ctm.Invert() ?? throw new EditConflictException(EditingText.TooBig);
        return ctm.Multiply(t).Multiply(inverse);
    }

    public void Transform(PageObject o, PdfMatrix t)
    {
        switch (o)
        {
            case ImageObject image:
                Wrap(PlaceOf(o), image.Op, image.Op, "q\n" + Matrix(Around(image.Placement, t)), "\nQ");
                break;
            case PathObject path:
                if (path.Clips) throw new EditConflictException(EditingText.ClipPath);
                Wrap(PlaceOf(o), path.FirstOp, path.PaintOp, "q\n" + Matrix(Around(path.Style.Ctm, t)), "\nQ");
                break;
            case TextObject block:
                TransformText(block, t);
                break;
        }
    }

    public void Delete(PageObject o)
    {
        var place = PlaceOf(o);
        var ops = o.Unit.Operations;
        switch (o)
        {
            case ImageObject image:
                Replace(place, ops[image.Op].Start, ops[image.Op].End, "");
                break;
            case PathObject path:
                // A path that also clips stays as a clip.
                if (path.Clips) Replace(place, ops[path.PaintOp].Start, ops[path.PaintOp].End, "n");
                else Replace(place, ops[path.FirstOp].Start, ops[path.PaintOp].End, "");
                break;
            case TextObject block:
                text.Delete(block.Range);
                break;
        }
    }

    /// <summary>Operators that set the look of a path for the length of the path alone.</summary>
    public void StylePath(PathObject path, RgbColor? fill, RgbColor? stroke, double? width)
    {
        if (path.Clips) throw new EditConflictException(EditingText.ClipPath);
        var w = new ContentWriter();
        if (fill is { } f) w.FillRgb(f.R / 255.0, f.G / 255.0, f.B / 255.0);
        if (stroke is { } s) w.StrokeRgb(s.R / 255.0, s.G / 255.0, s.B / 255.0);
        if (width is { } lw) w.LineWidth(lw);
        Wrap(PlaceOf(path), path.FirstOp, path.PaintOp, "q\n" + Encoding.Latin1.GetString(w.ToArray()), "\nQ");
    }

    public void Opacity(PageObject o, double opacity)
    {
        var state = new PdfDictionary();
        state["Type"] = new PdfName("ExtGState");
        state["ca"] = new PdfNumber(opacity);
        state["CA"] = new PdfNumber(opacity);
        var place = PlaceOf(o);
        string name = batch.AddResource(place, "ExtGState", state) ?? throw new EditConflictException(EditingText.SharedForm);
        string before = "q\n" + Encoding.Latin1.GetString(new ContentWriter().GraphicsState(name).ToArray());
        switch (o)
        {
            case ImageObject image:
                Wrap(place, image.Op, image.Op, before, "\nQ");
                break;
            case PathObject path:
                if (path.Clips) throw new EditConflictException(EditingText.ClipPath);
                Wrap(place, path.FirstOp, path.PaintOp, before, "\nQ");
                break;
            default:
                throw new EditConflictException(EditingText.NotAlone);
        }
    }

    /// <summary>Shows only the part of the picture inside <paramref name="area"/> (user space) by clipping its paint.</summary>
    public void Crop(ImageObject image, PdfRect area)
    {
        var clip = area.Intersect(image.Bounds);
        if (clip.IsEmpty) throw new EditConflictException(EditingText.TooBig);
        var inverse = image.Placement.Invert() ?? throw new EditConflictException(EditingText.TooBig);
        var w = new ContentWriter().Save();
        var corners = new[] { (clip.Left, clip.Bottom), (clip.Right, clip.Bottom), (clip.Right, clip.Top), (clip.Left, clip.Top) };
        for (int i = 0; i < 4; i++)
        {
            // At the paint the picture is the unit square, so the corners go there through the inverse of its placement.
            var (x, y) = inverse.Transform(corners[i].Item1, corners[i].Item2);
            if (i == 0) w.MoveTo(x, y);
            else w.LineTo(x, y);
        }
        w.Close().Clip();
        Wrap(PlaceOf(image), image.Op, image.Op, Encoding.Latin1.GetString(w.ToArray()), "\nQ");
    }
}
