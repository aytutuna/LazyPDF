using System.Text;

namespace LazyPDF.Core;

/// <summary>A PDF made from text: its bytes, page count and the code points the font had no glyph for.</summary>
public sealed record TextPdf(byte[] Bytes, int Pages, IReadOnlyList<int> Missing);

/// <summary>Plain text set on pages: wrapped at the margin, a form feed starting a new page, tabs as four spaces.</summary>
public static class PdfFromText
{
    private const double MinSide = 36;

    /// <summary>
    /// Text outside Latin-1 (Turkish ğ ş ı included) is drawn with an embedded subset of the
    /// family's font from <paramref name="fonts"/>; text a Standard 14 font can draw needs no source.
    /// </summary>
    /// <exception cref="InvalidOperationException">No font can draw the text; the message is <see cref="ExportText.NoFont"/>.</exception>
    /// <exception cref="ArgumentException">The margin or size leaves no room on the page.</exception>
    public static TextPdf Create(string text, IFontSource? fonts = null, PdfPageSetup? setup = null, string family = "Arial", double size = 11)
    {
        setup ??= new PdfPageSetup();
        var (width, height) = ExportPdf.Paper(setup, landscape: setup.Orientation == PdfOrientation.Landscape);
        double box = width - 2 * setup.Margin, boxHeight = height - 2 * setup.Margin;
        if (!(setup.Margin >= 0) || !(size > 0) || box < MinSide || boxHeight < MinSide) throw new ArgumentException("The margin or the size leaves no room on the page.", nameof(setup));

        // A form feed would pass for a line ending, so the text is cut at them first.
        var parts = text.Split('\f').Select(p => new string([.. p.ReplaceLineEndings("\n").Replace("\t", "    ").Where(c => c == '\n' || !char.IsControl(c))])).ToList();
        if (parts.Count > 1 && parts[^1].Length == 0) parts.RemoveAt(parts.Count - 1);
        var document = ExportPdf.NewDocument();
        var font = new PdfFontEmbedder(document, fonts).Add(family, FontStyles.Regular, parts) ?? throw new InvalidOperationException(ExportText.NoFont);

        double lineHeight = font.LineHeight(size);
        int perPage = Math.Max(1, (int)Math.Floor(boxHeight / lineHeight));
        var pages = new List<List<string>>();
        foreach (string part in parts)
        {
            var lines = font.Wrap(part, size, box);
            for (int at = 0; at < lines.Count || at == 0; at += perPage) pages.Add([.. lines.Skip(at).Take(perPage)]);
        }

        PageOperations.InsertBlank(document, 0, width, height, pages.Count);
        for (int i = 0; i < pages.Count; i++)
        {
            var page = document.Pages[i];
            string name = ContentResources.Add(document, ContentResources.ForEdit(document, page), "Font", font.Reference, "F");
            var content = new ContentWriter().BeginText().Font(name, size).MoveText(setup.Margin, height - setup.Margin - font.Ascent * size);
            bool first = true;
            foreach (string line in pages[i])
            {
                if (!first) content.MoveText(0, -lineHeight);
                first = false;
                if (line.Length > 0) content.Show(font.Encode(line));
            }
            content.EndText();
            page.Dictionary["Contents"] = document.Add(new PdfStream(new PdfDictionary(), content.ToArray()));
        }
        return new TextPdf(document.SaveRewrite(), pages.Count, font.Missing);
    }
}
