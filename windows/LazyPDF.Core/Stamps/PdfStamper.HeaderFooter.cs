namespace LazyPDF.Core;

public sealed partial class PdfStamper
{
    private StampRun HeaderFooter(int id, HeaderFooterSpec spec)
    {
        var targets = Targets(spec.Pages);
        int pageCount = document.Pages.Count;
        var slots = new List<(int Index, string[] Texts)>();
        foreach (int index in targets)
        {
            bool even = index % 2 == 1;
            var header = even ? spec.EvenHeader ?? spec.Header : spec.Header;
            var footer = even ? spec.EvenFooter ?? spec.Footer : spec.Footer;
            var values = new StampTokens.Values(spec.StartNumber + index, spec.StartNumber + pageCount - 1,
                spec.Bates?.Format(spec.Bates.Start + slots.Count) ?? "", spec);
            string[] texts = [.. new[] { header.Left, header.Center, header.Right, footer.Left, footer.Center, footer.Right }
                .Select(t => StampTokens.Expand(t, values))];
            if (texts.Any(t => t.Length > 0)) slots.Add((index, texts));
        }
        if (slots.Count == 0) return new StampRun(id, 0, spec.Bates?.Start ?? 0, []);

        var font = Font(spec.FontFamily, spec.FontStyle, slots.SelectMany(s => s.Texts));
        double size = spec.FontSize;
        string label = string.Join(" | ", new[] { spec.Header.Left, spec.Header.Center, spec.Header.Right, spec.Footer.Left, spec.Footer.Center, spec.Footer.Right }
            .Where(t => t.Length > 0));
        var kind = spec.Bates is null ? StampKind.HeaderFooter : StampKind.Bates;

        foreach (var (index, texts) in slots)
        {
            var page = document.Pages[index];
            var canvas = new StampCanvas(page, id, false);
            canvas.Writer.FillRgb(spec.Color.R, spec.Color.G, spec.Color.B);
            double top = canvas.Height - spec.MarginTop - font.Ascent * size;
            double bottom = spec.MarginBottom - font.Descent * size;
            DrawBand(canvas, id, font, size, spec.MarginX, top, texts[..3], "Header");
            DrawBand(canvas, id, font, size, spec.MarginX, bottom, texts[3..], "Footer");
            Finish(page, canvas, id, kind, label, false, font.Reference, null, null, null);
        }
        return new StampRun(id, slots.Count, spec.Bates is null ? 0 : spec.Bates.Start + slots.Count, font.Missing);
    }

    private static void DrawBand(StampCanvas canvas, int id, PdfDrawFont font, double size, double marginX, double baseline, string[] texts, string subtype)
    {
        if (texts.All(t => t.Length == 0)) return;
        canvas.BeginArtifact("Pagination", subtype);
        var writer = canvas.Writer.BeginText().Font(StampStreams.FontName(id), size);
        for (int i = 0; i < texts.Length; i++)
        {
            if (texts[i].Length == 0) continue;
            double width = font.Width(texts[i], size);
            double x = i switch { 0 => marginX, 1 => (canvas.Width - width) / 2, _ => canvas.Width - marginX - width };
            writer.TextMatrix(PdfMatrix.Translate(x, baseline)).Show(font, texts[i], size);
        }
        writer.EndText();
        canvas.EndArtifact();
    }
}
