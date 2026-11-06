namespace LazyPDF.Core;

// What the conversion removes or corrects without needing a font: actions, annotations, form flags, stream keys and
// filters, optional content and embedded files.
internal sealed partial class PdfAConversionRun
{
    private const long MaxSteps = 20_000_000;

    private static readonly string[] Intents = ["AbsoluteColorimetric", "RelativeColorimetric", "Saturation", "Perceptual"];

    private sealed record Parts(List<PdfDictionary> Dictionaries, List<PdfStream> Streams, List<PdfArray> Arrays);

    /// <summary>Every dictionary and stream reachable from the trailer, each once.</summary>
    private Parts Collect()
    {
        var parts = new Parts([], [], []);
        var visited = new HashSet<int>();
        var stack = new Stack<PdfObject>();
        stack.Push(_doc.Trailer);
        for (long steps = 0; stack.Count > 0 && steps < MaxSteps; steps++)
        {
            switch (stack.Pop())
            {
                case PdfReference reference:
                    if (visited.Add(reference.Number) && _doc.Get(reference.Number) is { } target) stack.Push(target);
                    break;
                case PdfArray array:
                    parts.Arrays.Add(array);
                    foreach (var item in array.Items) stack.Push(item);
                    break;
                case PdfStream stream:
                    parts.Streams.Add(stream);
                    stack.Push(stream.Dictionary);
                    break;
                case PdfDictionary dictionary:
                    parts.Dictionaries.Add(dictionary);
                    foreach (var (_, item) in dictionary.Entries) stack.Push(item);
                    break;
            }
        }
        return parts;
    }

    // Integers past 32 bits are a limit of the standard (6.1.12, 6.1.13); writers sometimes put float limits there as digits.
    private void ClampIntegers(Parts parts)
    {
        int clamped = 0;
        static bool TooBig(PdfObject? value) => value is PdfNumber { IsInteger: true } n && Math.Abs(n.Value) > int.MaxValue;
        PdfObject Limit(PdfObject value)
        {
            clamped++;
            return new PdfNumber(((PdfNumber)value).Value < 0 ? int.MinValue : int.MaxValue);
        }
        foreach (var d in parts.Dictionaries)
        {
            if (!d.Entries.Any(e => TooBig(e.Value))) continue;
            foreach (var (key, value) in d.Entries.ToList())
            {
                if (TooBig(value)) d[key] = Limit(value);
            }
        }
        foreach (var array in parts.Arrays)
        {
            for (int i = 0; i < array.Items.Count; i++)
            {
                if (TooBig(array.Items[i])) array.Items[i] = Limit(array.Items[i]);
            }
        }
        if (clamped > 0) Changed(PdfAText.IntegersClamped(clamped));
    }

    // With no blend mode, opacity or mask left to ask for it, a transparency group changes nothing on the page.
    private void RemoveGroups(Parts parts)
    {
        int removed = 0;
        foreach (var d in parts.Dictionaries)
        {
            if (_doc.Dict(d, "Group") is { } group && _doc.Name(group, "S") == "Transparency" && (_doc.Name(d, "Type") == "Page" || _doc.Name(d, "Subtype") == "Form") && d.Remove("Group")) removed++;
        }
        if (removed > 0) Changed(PdfAText.GroupsRemoved(removed));
    }

    private bool IsForbidden(PdfObject? value)
    {
        if (_doc.Resolve(value) is not PdfDictionary action) return false;
        string? type = _doc.Name(action, "S");
        return type is not null && (PdfAChecker.ForbiddenActions.Contains(type) || (type == "Named" && !PdfAChecker.NamedActions.Contains(_doc.Name(action, "N") ?? "")));
    }

    private static bool IsFieldOrWidget(PdfDocument document, PdfDictionary d) =>
        d.ContainsKey("FT") || document.Name(d, "Subtype") == "Widget" || (d.ContainsKey("T") && d.ContainsKey("Kids"));

    private void RemoveActions(Parts parts)
    {
        int removed = 0;
        foreach (var d in parts.Dictionaries)
        {
            foreach (string key in (ReadOnlySpan<string>)["A", "OpenAction", "Next"])
            {
                if (IsForbidden(d[key]) && d.Remove(key)) removed++;
            }
            if (_doc.Resolve(d["Next"]) is PdfArray chain) removed += chain.Items.RemoveAll(IsForbidden);
            if (_doc.Dict(d, "AA") is not { } triggers) continue;
            if (ReferenceEquals(d, _doc.Catalog) || IsFieldOrWidget(_doc, d))
            {
                d.Remove("AA");
                removed++;
                continue;
            }
            foreach (var (key, action) in triggers.Entries.ToList())
            {
                if (IsForbidden(action) && triggers.Remove(key)) removed++;
            }
            if (triggers.Count == 0) d.Remove("AA");
        }
        if (_doc.Dict(_doc.Catalog, "Names") is { } names && names.Remove("JavaScript")) removed++;
        if (removed > 0) Changed(PdfAText.ActionsRemoved(removed));
    }

    private string? FieldType(PdfDictionary field)
    {
        for (int hops = 0; field is not null && hops < 32; hops++)
        {
            if (_doc.Name(field, "FT") is { } type) return type;
            field = _doc.Dict(field, "Parent")!;
        }
        return null;
    }

    /// <summary>The normal appearance is there: a state dictionary for a button, a stream for the rest.</summary>
    private bool HasAppearance(PdfDictionary annotation)
    {
        var normal = _doc.Resolve(_doc.Dict(annotation, "AP")?["N"]);
        bool button = _doc.Name(annotation, "Subtype") == "Widget" && FieldType(annotation) == "Btn";
        return button ? normal is PdfDictionary : normal is PdfStream;
    }

    private void FixAnnotations()
    {
        var writer = new PdfAnnotationWriter(_doc, fonts);
        int dropped = 0, flagged = 0, drawn = 0;
        var pages = _doc.Pages;
        for (int p = 0; p < pages.Count; p++)
        {
            if (_doc.Array(pages[p].Dictionary, "Annots") is not { } annotations) continue;
            var kept = new List<PdfObject>();
            foreach (var item in annotations.Items.ToList())
            {
                if (_doc.Resolve(item) is not PdfDictionary annotation) continue;
                string? subtype = _doc.Name(annotation, "Subtype");
                bool allowed = subtype is not null && PdfAChecker.AllowedAnnotations(Part).Contains(subtype) && !(subtype == "FileAttachment" && Part == 4);
                if (!allowed)
                {
                    dropped++;
                    continue;
                }
                kept.Add(item);
                if (subtype == "Popup") continue;
                long flags = _doc.Integer(annotation, "F") ?? 0;
                long fixedFlags = (flags | 4) & ~(1L | 2 | 32);
                if (fixedFlags != flags)
                {
                    annotation["F"] = new PdfNumber(fixedFlags);
                    flagged++;
                }
                if (_doc.Dict(annotation, "AP") is { } ap)
                {
                    foreach (var (key, _) in ap.Entries.ToList())
                    {
                        if (key != "N") ap.Remove(key);
                    }
                }
                if (Part == 1) annotation.Remove("CA");
                if (subtype is "Link" or "Widget" || HasAppearance(annotation) || _doc.Rect(annotation, "Rect") is null) continue;
                try
                {
                    if (PdfAnnotations.Parse(_doc, annotation, item as PdfReference, p) is { } parsed && writer.Regenerate(parsed)) drawn++;
                }
                catch (Exception e) when (e is InvalidOperationException or PdfReadException)
                {
                    // No font for its text; the validator reports the missing appearance.
                }
            }
            if (kept.Count != annotations.Items.Count)
            {
                annotations.Items.Clear();
                annotations.Items.AddRange(kept);
            }
        }
        if (dropped > 0) Changed(PdfAText.AnnotationsRemoved(dropped));
        if (flagged > 0) Changed(PdfAText.FlagsSet(flagged));
        if (drawn > 0) Changed(PdfAText.AppearancesDrawn(drawn));
    }

    private void FixForm()
    {
        var form = PdfForm.Read(_doc, fonts);
        if (form.AcroForm is not { } acro) return;
        if (acro.Remove("XFA")) Changed(PdfAText.XfaRemoved);
        bool stale = form.NeedAppearances;
        var fields = form.Fields.Where(f => f.Kind != FieldKind.Signature && (stale || f.Widgets.Any(w => !HasAppearance(w.Dictionary)))).ToList();
        if (fields.Count > 0)
        {
            try
            {
                form.Regenerate(fields);
                Changed(PdfAText.FieldsDrawn(fields.Count));
            }
            catch (Exception e) when (e is InvalidOperationException or PdfReadException)
            {
                // A font for the field text is missing; the widgets without an appearance stay in the report.
            }
        }
        acro.Remove("NeedAppearances");
    }

    private void FixStreams(Parts parts)
    {
        int recoded = 0;
        foreach (var stream in parts.Streams)
        {
            var d = stream.Dictionary;
            foreach (string key in (ReadOnlySpan<string>)["F", "FFilter", "FDecodeParms"]) d.Remove(key);
            var filters = _doc.Resolve(d["Filter"]) switch
            {
                PdfName name => [name.Value],
                PdfArray array => array.Items.Select(i => (_doc.Resolve(i) as PdfName)?.Value ?? "").ToList(),
                _ => new List<string>(),
            };
            if (filters.Any(f => f is "LZWDecode" or "LZW" or "Crypt") && Recode(stream)) recoded++;
            switch (_doc.Name(d, "Subtype"))
            {
                case "Image":
                    d.Remove("Interpolate");
                    d.Remove("OPI");
                    d.Remove("Alternates");
                    if (_doc.Name(d, "Intent") is { } intent && !Intents.Contains(intent)) d.Remove("Intent");
                    break;
                case "Form":
                    d.Remove("Ref");
                    d.Remove("PS");
                    d.Remove("OPI");
                    if (_doc.Name(d, "Subtype2") == "PS") d.Remove("Subtype2");
                    break;
            }
        }
        foreach (var d in parts.Dictionaries)
        {
            if (_doc.Dict(d, "ExtGState") is not { } states) continue;
            CleanState(states);
            foreach (var (_, value) in states.Entries) CleanState(_doc.Resolve(value) as PdfDictionary);
        }
        if (recoded > 0) Changed(PdfAText.StreamsRecoded(recoded));
    }

    private void CleanState(PdfDictionary? state)
    {
        if (state is null) return;
        state.Remove("TR");
        state.Remove("HTP");
        if (_doc.Name(state, "TR2") != "Default") state.Remove("TR2");
        if (_doc.Name(state, "RI") is { } intent && !Intents.Contains(intent)) state.Remove("RI");
    }

    /// <summary>Takes the LZW (or Crypt) stage off a stream, keeping an image codec's own filter.</summary>
    private bool Recode(PdfStream stream)
    {
        var d = stream.Dictionary;
        try
        {
            var (filter, parameters, _) = _doc.DecodeSpec(stream);
            var decoded = PdfFilters.DecodeToCodec(_doc.RawData(stream), filter, parameters, 256L << 20);
            if (decoded.Codec is null)
            {
                stream.Data = PdfFilterEncoders.Flate(decoded.Data);
                d["Filter"] = new PdfName("FlateDecode");
                d.Remove("DecodeParms");
            }
            else
            {
                stream.Data = decoded.Data;
                d["Filter"] = new PdfName(decoded.Codec);
                if (decoded.Parameters is { } codecParameters) d["DecodeParms"] = codecParameters;
                else d.Remove("DecodeParms");
            }
            return true;
        }
        catch (PdfReadException)
        {
            return false;
        }
    }

    private void FixOptionalContent()
    {
        if (_doc.Dict(_doc.Catalog, "OCProperties") is not { } properties) return;
        if (Part == 1)
        {
            _doc.Catalog.Remove("OCProperties");
            Changed(PdfAText.LayersRemoved);
            return;
        }
        var configs = new List<PdfDictionary>();
        if (_doc.Dict(properties, "D") is not { } main)
        {
            main = new PdfDictionary();
            properties["D"] = main;
        }
        configs.Add(main);
        configs.AddRange(_doc.Array(properties, "Configs")?.Items.Take(256).Select(_doc.Resolve).OfType<PdfDictionary>() ?? []);
        var names = new HashSet<string>();
        var groups = _doc.Array(properties, "OCGs")?.Items.OfType<PdfReference>().Select(r => r.Number).ToHashSet() ?? [];
        for (int i = 0; i < configs.Count; i++)
        {
            var config = configs[i];
            string name = _doc.Resolve(config["Name"]) is PdfString s ? System.Text.Encoding.Latin1.GetString(s.Bytes) : "";
            if (name.Length == 0 || !names.Add(name))
            {
                string made = i == 0 ? "Default" : $"Configuration {i}";
                names.Add(made);
                config["Name"] = new PdfString(System.Text.Encoding.ASCII.GetBytes(made), isHex: false);
            }
            config.Remove("AS");
            if (_doc.Array(config, "Order") is { } order && groups.Except(Listed(order)).Any()) config.Remove("Order");
        }
    }

    private static HashSet<int> Listed(PdfArray order)
    {
        var numbers = new HashSet<int>();
        var stack = new Stack<PdfArray>([order]);
        for (int steps = 0; stack.Count > 0 && steps < 10_000; steps++)
        {
            foreach (var item in stack.Pop().Items)
            {
                if (item is PdfReference r) numbers.Add(r.Number);
                else if (item is PdfArray inner) stack.Push(inner);
            }
        }
        return numbers;
    }

    private void FixEmbeddedFiles(Parts parts)
    {
        int removed = 0, described = 0;
        foreach (var spec in parts.Dictionaries.Where(d => d.ContainsKey("EF")).ToList())
        {
            var stream = _doc.Dict(spec, "EF") is { } ef ? _doc.Stream(ef, "F") ?? _doc.Stream(ef, "UF") : null;
            if (Part == 3)
            {
                if (!spec.ContainsKey("AFRelationship")) spec["AFRelationship"] = new PdfName("Unspecified");
                if (!spec.ContainsKey("UF") && spec["F"] is { } file) spec["UF"] = file;
                if (stream is not null && _doc.Name(stream.Dictionary, "Subtype") is null) stream.Dictionary["Subtype"] = new PdfName("application/octet-stream");
                described++;
            }
            else if (Part != 2 || stream is null || !PdfAChecker.IsPdfA(_doc, stream))
            {
                spec.Remove("EF");
                removed++;
            }
        }
        if (Part is 1 or 4 && _doc.Dict(_doc.Catalog, "Names") is { } names && names.Remove("EmbeddedFiles")) removed++;
        if (removed > 0) Changed(PdfAText.AttachmentsRemoved(removed));
        if (described > 0) Changed(PdfAText.AttachmentsDescribed(described));
    }
}
