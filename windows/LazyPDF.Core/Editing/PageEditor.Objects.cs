namespace LazyPDF.Core;

public sealed partial class PageEditor
{
    /// <summary>Moves objects by (dx, dy) in user space with a matrix round each, leaving their coordinates as they are.</summary>
    public ObjectEditResult Move(IEnumerable<PageObject> objects, double dx, double dy) =>
        Transform(objects, PdfMatrix.Translate(dx, dy), "Move");

    /// <summary>Applies a user space transformation to each object.</summary>
    public ObjectEditResult Transform(IEnumerable<PageObject> objects, PdfMatrix matrix, string label = "Transform") =>
        EditObjects(label, objects, (editor, o) => editor.Transform(o, matrix));

    /// <summary>Scales the objects together so that the box around them becomes <paramref name="bounds"/>.</summary>
    public ObjectEditResult Resize(IEnumerable<PageObject> objects, PdfRect bounds)
    {
        var list = objects.ToList();
        if (list.Count == 0) return new ObjectEditResult(0, []);
        var box = Union(list);
        if (box.IsEmpty || bounds.IsEmpty) return new ObjectEditResult(0, [new SkippedObject(list[0].Id, EditingText.TooBig)]);
        var t = PdfMatrix.Translate(-box.Left, -box.Bottom)
            .Multiply(PdfMatrix.Scale(bounds.Width / box.Width, bounds.Height / box.Height))
            .Multiply(PdfMatrix.Translate(bounds.Left, bounds.Bottom));
        return Transform(list, t, "Resize");
    }

    /// <summary>Turns the objects together about the centre of the box around them, counter-clockwise.</summary>
    public ObjectEditResult Rotate(IEnumerable<PageObject> objects, double degrees)
    {
        var list = objects.ToList();
        if (list.Count == 0) return new ObjectEditResult(0, []);
        var box = Union(list);
        double cx = (box.Left + box.Right) / 2, cy = (box.Bottom + box.Top) / 2;
        double r = degrees * Math.PI / 180, cos = Math.Cos(r), sin = Math.Sin(r);
        var t = PdfMatrix.Translate(-cx, -cy).Multiply(new PdfMatrix(cos, sin, -sin, cos, 0, 0)).Multiply(PdfMatrix.Translate(cx, cy));
        return Transform(list, t, "Rotate");
    }

    /// <summary>Mirrors the objects together across the vertical (<paramref name="horizontal"/>) or horizontal middle line of the box around them.</summary>
    public ObjectEditResult Flip(IEnumerable<PageObject> objects, bool horizontal)
    {
        var list = objects.ToList();
        if (list.Count == 0) return new ObjectEditResult(0, []);
        var box = Union(list);
        double cx = (box.Left + box.Right) / 2, cy = (box.Bottom + box.Top) / 2;
        var t = PdfMatrix.Translate(-cx, -cy).Multiply(horizontal ? PdfMatrix.Scale(-1, 1) : PdfMatrix.Scale(1, -1)).Multiply(PdfMatrix.Translate(cx, cy));
        return Transform(list, t, "Flip");
    }

    private static PdfRect Union(List<PageObject> list) =>
        new(list.Min(o => o.Bounds.Left), list.Min(o => o.Bounds.Bottom), list.Max(o => o.Bounds.Right), list.Max(o => o.Bounds.Top));

    /// <summary>Takes the objects off the page. Text goes the way <see cref="DeleteText"/> takes it.</summary>
    public ObjectEditResult Delete(IEnumerable<PageObject> objects) =>
        EditObjects("Delete", objects, (editor, o) => editor.Delete(o));

    /// <summary>Shows only the part of the picture inside <paramref name="area"/>; the file keeps the whole picture.</summary>
    public ObjectEditResult Crop(ImageObject image, PdfRect area) =>
        EditObjects("Crop", [image], (editor, o) => editor.Crop((ImageObject)o, area));

    /// <summary>
    /// Puts another picture where this one is. JPEG data is embedded as it is; other files go
    /// through the editor's <see cref="IImageCodec"/>. With <paramref name="fit"/> the new picture
    /// keeps its proportions inside the old place, else it fills it.
    /// </summary>
    public ObjectEditResult ReplaceImage(ImageObject image, byte[] file, bool fit = true) =>
        EditObjects("Replace picture", [image], (editor, o) => editor.ReplaceImage((ImageObject)o, file, fit));

    /// <summary>Paints images and paths at the given opacity, 0 to 1.</summary>
    public ObjectEditResult SetOpacity(IEnumerable<PageObject> objects, double opacity) =>
        EditObjects("Opacity", objects, (editor, o) => editor.Opacity(o, Math.Clamp(opacity, 0, 1)));

    /// <summary>Moves an image or path one step or all the way in front of or behind the other things painted next to it. It has to sit in a q ... Q of its own.</summary>
    public ObjectEditResult Order(PageObject o, OrderMove move) =>
        EditObjects("Arrange", [o], (editor, x) => editor.Order(x, move));

    /// <summary>Recolours the fill or the stroke and sets the line width of paths; null leaves a value as it is.</summary>
    public ObjectEditResult SetPathStyle(IEnumerable<PathObject> paths, RgbColor? fill = null, RgbColor? stroke = null, double? lineWidth = null) =>
        EditObjects("Path style", paths, (editor, o) => editor.StylePath((PathObject)o, fill, stroke, lineWidth));

    /// <summary>The bytes of a picture: JPEG and JPEG 2000 data as stored, everything else as a PNG. Null when it cannot be read.</summary>
    public ExtractedImage? ExtractImage(ImageObject image)
    {
        var model = Model;
        var batch = new EditBatch(model.Document, model.Page, model.Scan);
        var editor = new ObjectEditor(model, batch, new TextEditor(model, batch, new TextBuilder(model.Document, batch, _fonts), _fonts)) { Codec = _codec };
        try
        {
            return editor.Extract(image);
        }
        catch (EditConflictException)
        {
            return null;
        }
    }

    private ObjectEditResult EditObjects(string label, IEnumerable<PageObject> objects, Action<ObjectEditor, PageObject> change)
    {
        var model = Model;
        var batch = new EditBatch(model.Document, model.Page, model.Scan);
        var builder = new TextBuilder(model.Document, batch, _fonts);
        var editor = new ObjectEditor(model, batch, new TextEditor(model, batch, builder, _fonts)) { Codec = _codec };
        foreach (var o in objects)
        {
            if (o.Id >= model.Objects.Count || !ReferenceEquals(model.Objects[o.Id], o)) throw new ArgumentException(EditingText.StaleObject, nameof(objects));
            editor.Try(o, () => change(editor, o));
        }
        if (editor.Changed == 0) return new ObjectEditResult(0, editor.Skipped);
        try
        {
            batch.Apply();
            builder.WriteAdditions();
        }
        catch (EditConflictException e)
        {
            return new ObjectEditResult(0, [.. editor.Skipped, new SkippedObject(-1, e.Message)]);
        }
        _session.Commit(label);
        _model = null;
        return new ObjectEditResult(editor.Changed, editor.Skipped);
    }
}
