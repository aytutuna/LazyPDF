using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// Applies what a <see cref="RedactionScan"/> found to the bytes of a content stream. Everything
/// the scan did not touch is copied as it was. A form that has to change is copied, the copy
/// edited and the call to it pointed at the copy, so other uses of the form keep what it shows.
/// </summary>
internal sealed class ContentRewriter(PdfDocument document, ImageRedactor images)
{
    private const int MaxFormOperations = 1_000_000;
    private const long MaxFormSize = 64L << 20;
    private static readonly string[] AltKeys = ["ActualText", "Alt", "E"];
    private static readonly string[] Construction = ["m", "l", "c", "v", "y", "h", "re"];

    private readonly record struct Cut(int Start, int End, string Text);

    /// <summary>The images and forms that were copied or dropped; the originals must not stay listed in resources that never paint them.</summary>
    public HashSet<PdfStream> Replaced { get; } = [];

    /// <summary>A resource dictionary of one's own to add names to: the categories are copied, what they point at is shared.</summary>
    public PdfDictionary Private(PdfDictionary? resources)
    {
        var copy = resources?.Copy() ?? new PdfDictionary();
        foreach (var (key, value) in copy.Entries.ToList())
        {
            if (document.Resolve(value) is PdfDictionary category) copy[key] = category.Copy();
        }
        return copy;
    }

    /// <summary>The new content of the stream. <paramref name="owner"/> is the page or form dictionary that gets the private resources.</summary>
    public byte[] Rewrite(ScanNode node, byte[] source, PdfDictionary owner, PdfDictionary? inherited, bool isForm)
    {
        var operations = isForm ? ContentParser.Parse(source, MaxFormOperations) : ContentParser.Parse(source);
        var resources = Private(document.Dict(owner, "Resources") ?? inherited);
        owner["Resources"] = resources;
        var cuts = new List<Cut>();
        var gone = new HashSet<int>();
        var replaced = new HashSet<string>();
        var properties = new HashSet<string>();

        void Replace(int index, string text)
        {
            cuts.Add(new Cut(operations[index].Start, operations[index].End, text));
            gone.Add(index);
            if (operations[index].Operator == "Do" && operations[index].Operands.Count > 0 && operations[index].Operands[0] is PdfName old) replaced.Add(old.Value);
        }

        foreach (var (index, edit) in node.Edits.OrderBy(e => e.Key))
        {
            var op = operations[index];
            switch (edit)
            {
                case DeleteEdit:
                    Replace(index, "");
                    break;
                case SurroundEdit s:
                    Replace(index, s.Before + Encoding.Latin1.GetString(source, op.Start, op.End - op.Start) + s.After);
                    break;
                case TextEdit t:
                    Replace(index, ShowText(op, t));
                    break;
                case PathEdit p:
                    RewritePath(operations, index, p, cuts, gone);
                    break;
                case ImageEdit image:
                    Replaced.Add(image.Image);
                    Replace(index, images.Redact(image.Image, image.Areas, image.Matrix) is { } reference
                        ? Do(ContentResources.Add(document, resources, "XObject", reference, "Rd"))
                        : "");
                    break;
            }
        }
        foreach (var (index, child) in node.Children.OrderBy(c => c.Key))
        {
            if (!child.HasEdits || child.Form is not { } form) continue;
            Replaced.Add(form);
            var copy = form.Dictionary.Copy();
            foreach (string key in (ReadOnlySpan<string>)["Metadata", "PieceInfo", "LastModified"]) copy.Remove(key);
            byte[] bytes;
            try
            {
                bytes = Rewrite(child, document.Data(form, MaxFormSize), copy, resources, true);
            }
            catch (PdfReadException)
            {
                Replace(index, "");
                continue;
            }
            copy["Filter"] = new PdfName("FlateDecode");
            copy.Remove("DecodeParms");
            var reference = document.Add(new PdfStream(copy, PdfFilterEncoders.Flate(bytes)));
            Replace(index, Do(ContentResources.Add(document, resources, "XObject", reference, "Rd")));
        }
        foreach (int index in node.DirtyMarked)
        {
            var op = operations[index];
            var described = op.Operands.Count >= 2 ? op.Operands[^1] switch
            {
                PdfDictionary inline => inline,
                PdfName key => document.Dict(document.Dict(resources, "Properties"), key.Value),
                _ => null,
            } : null;
            if (described is null) continue;
            var plain = described.Copy();
            foreach (string key in AltKeys) plain.Remove(key);
            cuts.Add(new Cut(op.Start, op.End, $"{op.Operands[0]} {plain} BDC"));
            gone.Add(index);
            if (op.Operands[^1] is PdfName name) properties.Add(name.Value);
        }

        DropUnused(operations, gone, replaced, properties, resources);
        var output = new MemoryStream();
        int at = 0;
        foreach (var cut in cuts.OrderBy(c => c.Start))
        {
            if (cut.Start < at) continue;
            output.Write(source, at, cut.Start - at);
            output.Write(Encoding.Latin1.GetBytes(cut.Text + "\n"));
            at = cut.End;
        }
        output.Write(source, at, source.Length - at);
        return output.ToArray();
    }

    private static string Do(string name) => $"{new PdfName(name)} Do";

    // The old name goes from the private resources once nothing in the stream calls it.
    private void DropUnused(IReadOnlyList<ContentOperation> operations, HashSet<int> gone, HashSet<string> replaced, HashSet<string> properties, PdfDictionary resources)
    {
        Drop(operations, gone, replaced, ["Do"], 0, document.Dict(resources, "XObject"));
        Drop(operations, gone, properties, ["BDC", "DP"], 1, document.Dict(resources, "Properties"));
    }

    private static void Drop(IReadOnlyList<ContentOperation> operations, HashSet<int> gone, HashSet<string> names, string[] users, int operand, PdfDictionary? category)
    {
        if (category is null) return;
        foreach (string name in names)
        {
            bool used = operations.Where((o, i) => !gone.Contains(i) && users.Contains(o.Operator) && o.Operands.Count > operand && o.Operands[operand] is PdfName n && n.Value == name).Any();
            if (!used) category.Remove(name);
        }
    }

    private static void RewritePath(IReadOnlyList<ContentOperation> operations, int index, PathEdit edit, List<Cut> cuts, HashSet<int> gone)
    {
        var paint = operations[index];
        if (edit.Clips)
        {
            cuts.Add(new Cut(paint.Start, paint.End, "n"));
            return;
        }
        int first = index;
        while (first > 0 && Construction.Contains(operations[first - 1].Operator)) first--;
        string text = "";
        if (edit.Pieces is { Count: > 0 } pieces && edit.Ctm.Invert() is { } back)
        {
            text = RedactionScan.Polygons(pieces.Select(r => (IReadOnlyList<(double X, double Y)>)Geometry.Corners(back, r.Left, r.Bottom, r.Right, r.Top)))
                   + paint.Operator;
        }
        cuts.Add(new Cut(operations[first].Start, paint.End, text));
        for (int i = first; i <= index; i++) gone.Add(i);
    }

    private static string ShowText(ContentOperation op, TextEdit edit)
    {
        var patch = new ShowPatch(op);
        foreach (var ((element, offset), (length, adjust)) in edit.Removed)
        {
            patch.Cut(element, offset, offset + length);
            if (adjust != 0) patch.Insert(element, offset, [new ShowShift(adjust)]);
        }
        return Encoding.Latin1.GetString(patch.Compile().Bytes);
    }
}
