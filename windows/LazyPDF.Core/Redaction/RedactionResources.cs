namespace LazyPDF.Core;

/// <summary>The /Resources of a page or form, built from what its content names instead of cleaned of what was removed.</summary>
internal static class RedactionResources
{
    public static readonly string[] Lists = ["XObject", "Font", "ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"];

    /// <summary>
    /// Gives <paramref name="owner"/> resources that hold the entries <paramref name="walk"/> found its content to use, however
    /// deep (a form without resources of its own reads the names of the one around it), and nothing else.
    /// </summary>
    public static void Rebuild(PdfDocument document, PdfDictionary owner, RedactionWalk walk)
    {
        var old = document.Dict(owner, "Resources");
        var fresh = new PdfDictionary();
        foreach (string category in Lists)
        {
            if (document.Dict(old, category) is not { } list) continue;
            var kept = new PdfDictionary();
            foreach (var (name, value) in list.Entries)
            {
                if (walk.Reads.Contains((list, name))) kept[name] = value;
            }
            if (kept.Count > 0) fresh[category] = kept;
        }
        // Names only, written in place: an object behind /ProcSet could be anything.
        if (document.Array(old, "ProcSet") is { } procedures) fresh["ProcSet"] = new PdfArray([.. procedures.Items.Select(document.Resolve).OfType<PdfName>()]);
        owner["Resources"] = fresh;
    }

    /// <summary>
    /// Takes out the font selections nothing is shown or painted after, until the font is chosen again or the saved state it
    /// was chosen in is restored. What a removed text left behind would otherwise keep its font, and the font's character map,
    /// in the file.
    /// </summary>
    public static byte[] DropIdleFonts(byte[] content)
    {
        var operations = ContentParser.Parse(content);
        var idle = new List<ContentOperation>();
        for (int i = 0; i < operations.Count; i++)
        {
            if (operations[i].Operator != "Tf") continue;
            bool live = false;
            int depth = 0;
            for (int j = i + 1; j < operations.Count && !live; j++)
            {
                switch (operations[j].Operator)
                {
                    case "Tj" or "TJ" or "'" or "\"" or "Do": live = true; break;
                    case "Tf" when depth == 0: j = operations.Count; break;
                    case "q": depth++; break;
                    case "Q" when depth-- == 0: j = operations.Count; break;
                }
            }
            if (!live) idle.Add(operations[i]);
        }
        if (idle.Count == 0) return content;
        var kept = new MemoryStream();
        int at = 0;
        foreach (var op in idle)
        {
            kept.Write(content, at, op.Start - at);
            at = op.End;
        }
        kept.Write(content, at, content.Length - at);
        return kept.ToArray();
    }

    /// <summary>The content streams of the page, in order.</summary>
    public static IEnumerable<PdfStream> Contents(PdfDocument document, PdfPage page)
    {
        var contents = document.Resolve(page.Dictionary["Contents"]);
        foreach (var item in contents is PdfArray array ? array.Items : [contents ?? PdfNull.Instance])
        {
            if (document.Resolve(item) is PdfStream stream) yield return stream;
        }
    }
}
