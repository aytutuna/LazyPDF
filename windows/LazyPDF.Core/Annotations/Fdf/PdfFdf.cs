using System.Text;

namespace LazyPDF.Core;

/// <summary>Reading and writing FDF files (ISO 32000-1 12.7.7), and moving annotations between them and a document.</summary>
public static class PdfFdf
{
    private const int MaxObjects = 200_000;
    private const int MaxFieldDepth = 32;

    /// <summary>
    /// Reads an FDF file. Objects are found by scanning, as the reader does for a damaged PDF, so a
    /// file whose table is wrong still reads. Throws <see cref="PdfReadException"/> (Damaged) when no /FDF
    /// dictionary is found.
    /// </summary>
    public static FdfFile Read(byte[] data)
    {
        var lexer = new PdfLexer(new PdfArrayBytes(data));
        var objects = new Dictionary<int, PdfObject>();
        PdfDictionary? trailer = null;
        for (int guard = 0; lexer.Position < data.Length && guard < 4_000_000; guard++)
        {
            lexer.SkipWhiteSpace();
            long start = lexer.Position;
            if (start >= data.Length) break;
            try
            {
                if (lexer.TryReadUnsigned() is { } number)
                {
                    if (lexer.TryReadUnsigned() is not null && lexer.ReadKeyword() == "obj" && number <= int.MaxValue)
                    {
                        var value = lexer.ReadObject();
                        if (value is PdfStream stream) value = WithData(stream, data, lexer);
                        if (objects.Count < MaxObjects) objects[(int)number] = value;
                    }
                    else
                    {
                        lexer.Position = start;
                        lexer.ReadKeyword();
                    }
                }
                else
                {
                    string word = lexer.ReadKeyword();
                    if (word == "trailer") trailer = lexer.ReadObject() as PdfDictionary ?? trailer;
                    else if (word.Length == 0) lexer.Position++;
                }
            }
            catch (PdfReadException)
            {
                lexer.Position = Math.Max(lexer.Position, start + 1);
            }
        }

        var fdf = new FdfFile();
        foreach (var (number, value) in objects) fdf.Add(number, value);
        var root = fdf.Resolve(trailer?["Root"]) as PdfDictionary ?? objects.Values.OfType<PdfDictionary>().FirstOrDefault(d => d.ContainsKey("FDF"));
        if (fdf.Resolve(root?["FDF"]) is not PdfDictionary body) throw PdfReadException.Damaged("There is no FDF dictionary in the file.");
        // The catalog is rewritten by Write; keeping it would leave a second copy of the body behind.
        foreach (var number in fdf.Objects.Where(o => ReferenceEquals(o.Value, root)).Select(o => o.Key).ToList()) fdf.Objects.Remove(number);

        fdf.FileName = fdf.Resolve(body["F"]) switch
        {
            PdfString text => PdfText.Decode(text.Bytes),
            PdfDictionary spec when fdf.Resolve(spec["UF"] ?? spec["F"]) is PdfString name => PdfText.Decode(name.Bytes),
            _ => null,
        };
        int count = 0;
        if (fdf.Resolve(body["Fields"]) is PdfArray fields) fdf.Fields.AddRange(ReadFields(fdf, fields, 0, ref count));
        if (fdf.Resolve(body["Annots"]) is PdfArray annots)
        {
            foreach (var item in annots.Items.Take(PdfAnnotations.MaxAnnotations))
            {
                if (fdf.Resolve(item) is PdfDictionary d && d["Subtype"] is PdfName)
                {
                    fdf.Annotations.Add(new FdfAnnotation((int)Math.Clamp((d["Page"] as PdfNumber)?.Integer ?? 0, 0, int.MaxValue), d));
                }
            }
        }
        return fdf;
    }

    private static PdfObject WithData(PdfStream stream, byte[] data, PdfLexer lexer)
    {
        int start = (int)Math.Min(stream.DataOffset, data.Length);
        int end;
        if (stream.Dictionary["Length"] is PdfNumber { Integer: { } length and >= 0 } && start + length <= data.Length && EndsWithKeyword(data, (int)(start + length)))
        {
            end = (int)(start + length);
        }
        else
        {
            int found = data.AsSpan(start).IndexOf("endstream"u8);
            end = found < 0 ? data.Length : start + found;
            if (end > start && data[end - 1] == '\n') end--;
            if (end > start && data[end - 1] == '\r') end--;
        }
        lexer.Position = end;
        return new PdfStream(stream.Dictionary, data[start..end]);
    }

    private static bool EndsWithKeyword(byte[] data, int at)
    {
        while (at < data.Length && PdfLexer.IsWhiteSpace(data[at])) at++;
        return data.AsSpan(at).StartsWith("endstream"u8);
    }

    private static List<FdfField> ReadFields(FdfFile fdf, PdfArray array, int depth, ref int count)
    {
        var fields = new List<FdfField>();
        foreach (var item in array.Items)
        {
            if (count++ >= MaxObjects) break;
            if (fdf.Resolve(item) is not PdfDictionary d) continue;
            string name = fdf.Resolve(d["T"]) is PdfString t ? PdfText.Decode(t.Bytes) : "";
            var kids = depth < MaxFieldDepth && fdf.Resolve(d["Kids"]) is PdfArray k ? ReadFields(fdf, k, depth + 1, ref count) : [];
            fields.Add(new FdfField(name, fdf.Resolve(d["V"]), kids));
        }
        return fields;
    }

    /// <summary>The file's bytes. The annotations are given objects of their own first (see <see cref="FdfFile"/>).</summary>
    public static byte[] Write(FdfFile fdf)
    {
        fdf.Link();
        var number = new Dictionary<PdfDictionary, int>();
        foreach (var (n, value) in fdf.Objects)
        {
            if (value is PdfDictionary dictionary) number[dictionary] = n;
        }
        var body = new PdfDictionary();
        if (fdf.FileName is { Length: > 0 } name) body["F"] = PdfText.ToObject(name);
        if (fdf.Fields.Count > 0) body["Fields"] = new PdfArray([.. fdf.Fields.Select(FieldObject)]);
        var annots = new List<PdfObject>();
        foreach (var annotation in fdf.Annotations)
        {
            annotation.Dictionary["Page"] = new PdfNumber(annotation.PageIndex);
            annots.Add(new PdfReference(number[annotation.Dictionary], 0));
        }
        if (annots.Count > 0) body["Annots"] = new PdfArray(annots);

        int rootNumber = (fdf.Objects.Count == 0 ? 0 : fdf.Objects.Keys.Max()) + 1;
        var output = new MemoryStream();
        Put(output, "%FDF-1.2\n%âãÏÓ\n");
        Put(output, $"{rootNumber} 0 obj\n<</FDF {body}>>\nendobj\n");
        foreach (var (n, value) in fdf.Objects.OrderBy(o => o.Key))
        {
            if (value is PdfStream stream)
            {
                var dictionary = stream.Dictionary.Copy();
                byte[] payload = stream.Data ?? [];
                dictionary["Length"] = new PdfNumber(payload.Length);
                Put(output, $"{n} 0 obj\n{dictionary}\nstream\n");
                output.Write(payload);
                Put(output, "\nendstream\nendobj\n");
            }
            else
            {
                Put(output, $"{n} 0 obj\n{value}\nendobj\n");
            }
        }
        Put(output, $"trailer\n<</Root {rootNumber} 0 R>>\n%%EOF\n");
        return output.ToArray();
    }

    private static PdfObject FieldObject(FdfField field)
    {
        var d = new PdfDictionary { ["T"] = PdfText.ToObject(field.Name) };
        if (field.Value is not null) d["V"] = field.Value;
        if (field.Kids.Count > 0) d["Kids"] = new PdfArray([.. field.Kids.Select(FieldObject)]);
        return d;
    }

    private static void Put(MemoryStream output, string text) => output.Write(Encoding.Latin1.GetBytes(text));

    /// <summary>
    /// The annotations of the document as an FDF file: everything but links and form widgets, with
    /// popups, replies, appearance streams and attachments copied along. <paramref name="types"/> narrows them.
    /// </summary>
    public static FdfFile Export(PdfDocument document, string? fileName = null, IReadOnlySet<AnnotationType>? types = null)
    {
        var fdf = new FdfFile { FileName = fileName };
        var chosen = new List<PdfAnnotation>();
        var all = PdfAnnotations.ReadAll(document);
        var kept = new HashSet<int>();
        foreach (var a in all.Where(a => a.Type is not (AnnotationType.Widget or AnnotationType.Link or AnnotationType.Popup) && (types?.Contains(a.Type) ?? true)))
        {
            chosen.Add(a);
            if (a.Reference is { } r) kept.Add(r.Number);
        }
        foreach (var popup in all.Where(a => a.Type == AnnotationType.Popup && a.Dictionary["Parent"] is PdfReference p && kept.Contains(p.Number))) chosen.Add(popup);

        var copier = new ObjectCopier(document.Resolve, document.RawData, fdf.Reserve, fdf.Store);
        var targets = new List<PdfReference>();
        foreach (var a in chosen)
        {
            var target = fdf.Reserve();
            targets.Add(target);
            if (a.Reference is { } source) copier.Preload(source.Number, target);
        }
        var inside = chosen.Select(a => a.Reference?.Number).OfType<int>().ToHashSet();
        for (int i = 0; i < chosen.Count; i++)
        {
            var a = chosen[i];
            var d = a.Dictionary.Copy();
            d.Remove("P");
            d.Remove("StructParent"); // a number into the tag tree of this file
            foreach (string key in (ReadOnlySpan<string>)["Parent", "IRT", "Popup"])
            {
                if (d[key] is PdfReference r && !inside.Contains(r.Number)) d.Remove(key);
            }
            d["Page"] = new PdfNumber(a.PageIndex);
            if (!d.ContainsKey("NM")) d["NM"] = PdfText.ToObject(Guid.NewGuid().ToString());
            var copy = (PdfDictionary)copier.Copy(d);
            fdf.Store(targets[i], copy);
            fdf.Annotations.Add(new FdfAnnotation(a.PageIndex, copy));
        }
        return fdf;
    }

    /// <summary>
    /// Adds the annotations of <paramref name="fdf"/> to the document. One without an appearance gets one
    /// where this layer can draw its kind; one whose page is not in the document, or whose /NM an annotation
    /// of that page already has, is skipped.
    /// </summary>
    public static FdfImportResult Import(PdfDocument document, FdfFile fdf, IFontSource? fonts = null)
    {
        fdf.Link();
        var accepted = new List<(FdfAnnotation Source, PdfPage Page, PdfReference Target)>();
        var names = new Dictionary<int, Dictionary<string, PdfReference?>>();
        var present = new Dictionary<int, PdfReference>();
        int skipped = 0;
        var copier = new ObjectCopier(fdf.Resolve, s => s.Data ?? [], () => document.Add(PdfNull.Instance), (r, v) => document.Set(r.Number, v));
        var numberOf = fdf.Objects.Where(o => o.Value is PdfDictionary).ToDictionary(o => (PdfDictionary)o.Value, o => o.Key);
        var acceptedNumbers = new HashSet<int>();
        // Popups after the annotations that own them, so that one whose owner was skipped is skipped too.
        foreach (var source in fdf.Annotations.OrderBy(a => (a.Dictionary["Subtype"] as PdfName)?.Value == "Popup"))
        {
            string? subtype = (source.Dictionary["Subtype"] as PdfName)?.Value;
            if (subtype is null or "Widget" || source.PageIndex < 0 || source.PageIndex >= document.Pages.Count)
            {
                skipped++;
                continue;
            }
            var page = document.Pages[source.PageIndex];
            if (!names.TryGetValue(page.Index, out var taken))
            {
                taken = [];
                foreach (var existing in PdfAnnotations.Read(document, page))
                {
                    if (existing.Name is { } known) taken[known] = existing.Reference;
                }
                names[page.Index] = taken;
            }
            if (subtype == "Popup" && source.Dictionary["Parent"] is PdfReference owner && !acceptedNumbers.Contains(owner.Number))
            {
                skipped++;
                continue;
            }
            if (source.Dictionary["NM"] is PdfString nm)
            {
                string key = PdfText.Decode(nm.Bytes);
                if (taken.ContainsKey(key))
                {
                    if (taken[key] is { } live) present[numberOf[source.Dictionary]] = live;
                    skipped++;
                    continue;
                }
                taken[key] = null;
            }
            var target = document.Add(PdfNull.Instance);
            accepted.Add((source, page, target));
            copier.Preload(numberOf[source.Dictionary], target);
            acceptedNumbers.Add(numberOf[source.Dictionary]);
        }

        var builder = new AppearanceBuilder(document, fonts);
        int withoutAppearance = 0;
        foreach (var (source, page, target) in accepted)
        {
            // A link to an annotation that was not taken would drag it in as a loose object.
            var original = source.Dictionary.Copy();
            PdfReference? replyTo = null;
            foreach (string key in (ReadOnlySpan<string>)["Parent", "IRT", "Popup"])
            {
                if (original[key] is PdfReference r && !acceptedNumbers.Contains(r.Number))
                {
                    // A reply to an annotation the document already had is a reply to that one.
                    if (key == "IRT") present.TryGetValue(r.Number, out replyTo);
                    original.Remove(key);
                }
            }
            var d = (PdfDictionary)copier.Copy(original);
            if (replyTo is not null) d["IRT"] = replyTo;
            else if (d["IRT"] is PdfString by)
            {
                if (names[page.Index].GetValueOrDefault(PdfText.Decode(by.Bytes)) is { } named) d["IRT"] = named;
                else d.Remove("IRT");
            }
            d.Remove("Page");
            d["P"] = page.Reference;
            document.Set(target.Number, d);
            if (document.Array(page.Dictionary, "Annots") is { } list) list.Items.Add(target);
            else page.Dictionary["Annots"] = new PdfArray([target]);
            if (d["AP"] is null && AppearanceBuilder.CanDraw(PdfAnnotations.Parse(document, d, target)!.Type))
            {
                try
                {
                    if (!builder.Apply(d)) withoutAppearance++;
                }
                catch (InvalidOperationException)
                {
                    withoutAppearance++;
                }
            }
        }
        return new FdfImportResult(accepted.Count, skipped, withoutAppearance);
    }
}

/// <summary>What <see cref="PdfFdf.Import"/> did: annotations added, entries skipped, and added ones left without an appearance.</summary>
public sealed record FdfImportResult(int Imported, int Skipped, int WithoutAppearance);
