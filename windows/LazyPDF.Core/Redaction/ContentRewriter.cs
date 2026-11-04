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
    // What a form is drawn from (8.10); /AF, /Metadata, /PieceInfo, /OPI and the like are not copied along.
    private static readonly string[] FormKept = ["Type", "Subtype", "FormType", "BBox", "Matrix", "Resources", "Group", "OC", "StructParent", "StructParents"];
    private static readonly string[] Construction = ["m", "l", "c", "v", "y", "h", "re"];
    private static readonly string[] Paints = ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"];

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
        var leads = new Dictionary<int, double>();
        var emptied = new HashSet<int>();
        string?[]? fonts = null;

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
                    Replace(index, ShowText(operations, fonts ??= FontsInForce(operations), index, t, leads, emptied));
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
        foreach (var (index, lead) in leads)
        {
            if (operations[index].Operands.Count == 0) continue;
            var op = operations[index];
            cuts.Add(new Cut(op.Start, op.End, Show(Merge([new PdfNumber(lead), .. Elements(op)]))));
        }
        MergePositions(operations, emptied, cuts);
        DropMatrices(operations, emptied, cuts);
        foreach (var (index, child) in node.Children.OrderBy(c => c.Key))
        {
            // A form the scan could not follow is dropped at its call; a copy would only hold what the original does.
            if (!child.HasEdits || child.Form is not { } form || node.Edits.GetValueOrDefault(index) is DeleteEdit) continue;
            Replaced.Add(form);
            var copy = new PdfDictionary();
            foreach (string key in FormKept)
            {
                if (form.Dictionary[key] is { } value) copy[key] = value;
            }
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

    // The construction operators of the path go one by one: colour and state operators may sit between
    // them and the paint, and have to stay. The new outline is written where the paint was. The rule of
    // a clip is the one of its own W or W*, not of the paint operator that follows (8.5.4).
    private static void RewritePath(IReadOnlyList<ContentOperation> operations, int index, PathEdit edit, List<Cut> cuts, HashSet<int> gone)
    {
        var paint = operations[index];
        bool evenOdd = false;
        for (int i = index - 1; i >= 0 && !Paints.Contains(operations[i].Operator); i--)
        {
            if (!Construction.Contains(operations[i].Operator) && operations[i].Operator is not ("W" or "W*")) continue;
            evenOdd |= operations[i].Operator == "W*";
            cuts.Add(new Cut(operations[i].Start, operations[i].End, ""));
            gone.Add(i);
        }
        string text = "";
        if (edit.Ctm.Invert() is { } back)
        {
            text = RedactionPaths.Polygons(edit.Remains.Select(p => (IReadOnlyList<(double X, double Y)>)p.Select(q => back.Transform(q.X, q.Y)).ToList()));
        }
        if (edit.Clips)
        {
            // A clip with nothing left of it still has to clip: to a point, so that what it guarded stays hidden.
            if (text.Length == 0) text = "0 0 m\n0 0 l\nh\n";
            text += (evenOdd ? "W*" : "W") + " n";
        }
        else if (text.Length > 0) text += paint.Operator;
        cuts.Add(new Cut(paint.Start, paint.End, text));
        gone.Add(index);
    }

    private const int Over = -1;
    private const int Keep = -2;

    // The patch writes one shift for a run of removed glyphs. A shift at the end of the operator moves to the
    // front of the next show on the same line, so that a run over several operators keeps its total and no
    // width per operator; at the end of a line, when the next show starts from a position of its own, it goes.
    private static string ShowText(IReadOnlyList<ContentOperation> operations, string?[] fonts, int index, TextEdit edit, Dictionary<int, double> leads, HashSet<int> emptied)
    {
        var op = operations[index];
        var patch = new ShowPatch(op);
        (int Element, int Start, int End, double Adjust)? run = null;
        void Flush()
        {
            if (run is not { } r) return;
            patch.Cut(r.Element, r.Start, r.End);
            if (r.Adjust != 0) patch.Insert(r.Element, r.Start, [new ShowShift(r.Adjust)]);
            run = null;
        }
        foreach (var ((element, offset), (length, adjust)) in edit.Removed.OrderBy(e => e.Key.Element).ThenBy(e => e.Key.Offset))
        {
            if (run is { } r && r.Element == element && r.End == offset) run = (element, r.Start, offset + length, r.Adjust + adjust);
            else
            {
                Flush();
                run = (element, offset, offset + length, adjust);
            }
        }
        Flush();

        byte[] written = patch.Compile().Bytes;
        var parsed = ContentParser.Parse(written);
        var show = parsed.FirstOrDefault(o => o.Operator is "Tj" or "TJ");
        var items = new List<PdfObject>();
        if (leads.Remove(index, out double lead)) items.Add(new PdfNumber(lead));
        if (show is not null) items.AddRange(Elements(show));
        items = Merge(items);
        int next = Next(operations, fonts, index);
        if (next != Keep && items.Count > 0 && items[^1] is PdfNumber last)
        {
            items.RemoveAt(items.Count - 1);
            if (next >= 0) leads[next] = leads.GetValueOrDefault(next) + last.Value;
        }
        if (op.Operator is "Tj" or "TJ" && !items.Any(i => i is PdfString)) emptied.Add(index);

        var output = new StringBuilder();
        foreach (var part in parsed)
        {
            if (part != show) output.Append(Encoding.Latin1.GetString(written, part.Start, part.End - part.Start)).Append('\n');
            else if (items.Count > 0) output.Append(Show(items)).Append('\n');
        }
        if (show is null && items.Count > 0) output.Append(Show(items));
        return output.ToString().TrimEnd('\n');
    }

    // The last Tf at or before each operation, as written.
    private static string?[] FontsInForce(IReadOnlyList<ContentOperation> operations)
    {
        var fonts = new string?[operations.Count];
        string? font = null;
        for (int i = 0; i < fonts.Length; i++)
        {
            if (operations[i].Operator == "Tf") font = operations[i].ToString();
            fonts[i] = font;
        }
        return fonts;
    }

    // The next show operator on the same line, or what ends the line first. A change of font size or scale between
    // them would change what a shift means; the same font set again does not.
    private static int Next(IReadOnlyList<ContentOperation> operations, string?[] fonts, int index)
    {
        bool changed = false;
        string? font = fonts[index];
        for (int i = index + 1; i < operations.Count; i++)
        {
            switch (operations[i].Operator)
            {
                case "Tj" or "TJ":
                    return changed ? Keep : i;
                case "Td" or "TD" or "Tm" or "T*" or "'" or "\"" or "ET" or "BT":
                    return Over;
                case "Tf" when operations[i].ToString() == font:
                    break;
                case "Tf" or "Tz" or "q" or "Q" or "gs":
                    changed = true;
                    break;
            }
        }
        return Over;
    }

    private static IEnumerable<PdfObject> Elements(ContentOperation show) =>
        show.Operands[^1] is PdfArray array ? array.Items : [show.Operands[^1]];

    // Shifts that meet become one, the original kerning between two removed runs included.
    private static List<PdfObject> Merge(IEnumerable<PdfObject> source)
    {
        var items = new List<PdfObject>();
        foreach (var item in source)
        {
            if (item is PdfNumber n && items.Count > 0 && items[^1] is PdfNumber last) items[^1] = new PdfNumber(last.Value + n.Value);
            else items.Add(item);
        }
        items.RemoveAll(i => i is PdfNumber { Value: 0 });
        return items;
    }

    private static string Show(List<PdfObject> items) => items is [PdfString only] ? $"{only} Tj" : $"{new PdfArray(items)} TJ";

    // A position set between shows that were all taken out has nothing to place: it goes, or is added to the
    // relative move that follows (a Td after a Td, any move before a TD that is level), or is overwritten by the
    // matrix that follows. A TD also sets the leading (9.4.2), which a dropped one passes on as a TL.
    private static void MergePositions(IReadOnlyList<ContentOperation> operations, HashSet<int> emptied, List<Cut> cuts)
    {
        var moves = new Dictionary<int, (double X, double Y)>();
        var text = new Dictionary<int, string>();
        for (int p = 0; p < operations.Count; p++)
        {
            var op = operations[p];
            if (op.Operator is not ("Td" or "TD" or "Tm") || (op.Operator != "Tm" && (op.Number(0) is null || op.Number(1) is null))) continue;
            int q = p + 1;
            bool any = false;
            for (; q < operations.Count; q++)
            {
                if (emptied.Contains(q)) any = true;
                else if (operations[q].Operator is "Tj" or "TJ" or "Td" or "TD" or "Tm" or "T*" or "'" or "\"" or "ET" or "BT" or "q" or "Q") break;
            }
            if (!any) continue;
            string after = q < operations.Count ? operations[q].Operator : "ET";
            var (px, py) = op.Operator == "Tm" ? (0, 0) : moves.GetValueOrDefault(p, (op.Number(0)!.Value, op.Number(1)!.Value));
            if (after is "ET" or "BT" or "Tm") text[p] = op.Operator == "TD" ? $"{new PdfNumber(0 - py).Text} TL" : "";
            else if (after is "Td" or "TD" && op.Operator != "Tm" && operations[q].Number(0) is { } x && operations[q].Number(1) is { } y && (after == "TD" ? py == 0 : op.Operator == "Td"))
            {
                moves[q] = (x + px, y + py);
                text[p] = "";
                text[q] = $"{new PdfNumber(x + px).Text} {new PdfNumber(y + py).Text} {after}";
            }
        }
        foreach (var (index, replacement) in text) cuts.Add(new Cut(operations[index].Start, operations[index].End, replacement));
    }

    // The matrix of a q block that holds nothing but shows taken out places nothing, and left in it gives the
    // position of the removed run. The block restores the state, so nothing after it depends on the matrix.
    private static void DropMatrices(IReadOnlyList<ContentOperation> operations, HashSet<int> emptied, List<Cut> cuts)
    {
        if (emptied.Count == 0) return;
        var enclosing = new int[operations.Count];
        var close = new Dictionary<int, int>();
        var open = new Stack<int>();
        for (int i = 0; i < operations.Count; i++)
        {
            enclosing[i] = open.Count > 0 ? open.Peek() : -1;
            if (operations[i].Operator == "q") open.Push(i);
            else if (operations[i].Operator == "Q" && open.Count > 0) close[open.Pop()] = i;
        }
        var seen = new HashSet<int>();
        foreach (int shown in emptied)
        {
            for (int q = enclosing[shown]; q >= 0 && close.TryGetValue(q, out int end) && seen.Add(q); q = enclosing[q])
            {
                var block = Enumerable.Range(q + 1, end - q - 1).ToList();
                if (block.Any(i => Paints.Contains(operations[i].Operator) || operations[i].Operator is "sh" or "Do" or "BI" or "'" or "\"" || operations[i].Operator is "Tj" or "TJ" && !emptied.Contains(i))) break;
                foreach (int i in block.Where(i => operations[i].Operator == "cm")) cuts.Add(new Cut(operations[i].Start, operations[i].End, ""));
            }
        }
    }
}
