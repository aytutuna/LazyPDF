using System.Text;
using static LazyPDF.Core.ExportXml;

namespace LazyPDF.Core;

// From Lazy Scan's DocxWriter.cs: the package layout, the inline picture and the page setup, grown
// from one run per paragraph to styles, lists and tables, and deflated.

/// <summary>
/// The Word document (.docx) of an <see cref="ExportDocument"/>: headings, paragraphs with bold and
/// italic runs, bulleted and numbered lists, tables, and pictures where they stood. Each page after
/// the first starts on a new page. The paper is the first page's size; the margins are what the
/// content leaves free, between 0.25 and 2 inches.
/// </summary>
public static class DocxWriter
{
    private const int MinTwips = 144, MaxTwips = 31680;
    private const string W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private const string RelNs = "http://schemas.openxmlformats.org/package/2006/relationships";
    private const string OfficeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

    public static byte[] Make(ExportDocument document)
    {
        var media = new List<ExportImage>();
        var mediaIndex = new Dictionary<ExportImage, int>(ReferenceEqualityComparer.Instance);
        var (width, height) = PaperTwips(document);
        var (top, right, bottom, left) = MarginsTwips(document, width, height);
        string body = Body(document, width - left - right, media, mediaIndex, width, height, top, right, bottom, left);

        var types = new StringBuilder(Header);
        types.Append("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">")
            .Append("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>")
            .Append("<Default Extension=\"xml\" ContentType=\"application/xml\"/>");
        if (media.Any(m => m.IsJpeg)) types.Append("<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>");
        if (media.Any(m => !m.IsJpeg)) types.Append("<Default Extension=\"png\" ContentType=\"image/png\"/>");
        types.Append("<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>")
            .Append("<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>")
            .Append("<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>");
        bool title = !string.IsNullOrWhiteSpace(document.Title);
        if (title) types.Append("<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>");
        types.Append("</Types>");

        var rels = new StringBuilder(Header);
        rels.Append("<Relationships xmlns=\"").Append(RelNs).Append("\">")
            .Append("<Relationship Id=\"rId1\" Type=\"").Append(OfficeRel).Append("/officeDocument\" Target=\"word/document.xml\"/>");
        if (title) rels.Append("<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>");
        rels.Append("</Relationships>");

        var documentRels = new StringBuilder(Header);
        documentRels.Append("<Relationships xmlns=\"").Append(RelNs).Append("\">")
            .Append("<Relationship Id=\"rId1\" Type=\"").Append(OfficeRel).Append("/styles\" Target=\"styles.xml\"/>")
            .Append("<Relationship Id=\"rId2\" Type=\"").Append(OfficeRel).Append("/numbering\" Target=\"numbering.xml\"/>");
        for (int i = 0; i < media.Count; i++)
            documentRels.Append("<Relationship Id=\"rId").Append(I(i + 3)).Append("\" Type=\"").Append(OfficeRel).Append("/image\" Target=\"media/image").Append(I(i + 1)).Append('.').Append(media[i].Extension).Append("\"/>");
        documentRels.Append("</Relationships>");

        var entries = new List<ExportZipEntry>
        {
            new("[Content_Types].xml", Utf8(types.ToString())),
            new("_rels/.rels", Utf8(rels.ToString())),
            new("word/document.xml", Utf8(body)),
            new("word/styles.xml", Utf8(Styles(document.BodySize))),
            new("word/numbering.xml", Utf8(Numbering(document))),
            new("word/_rels/document.xml.rels", Utf8(documentRels.ToString())),
        };
        if (title)
        {
            entries.Add(new("docProps/core.xml", Utf8(Header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>"
                + Escape(document.Title!) + "</dc:title></cp:coreProperties>")));
        }
        for (int i = 0; i < media.Count; i++) entries.Add(new($"word/media/image{i + 1}.{media[i].Extension}", media[i].Data));
        return ExportZip.Make(entries);
    }

    private static string Body(ExportDocument document, int contentTwips, List<ExportImage> media, Dictionary<ExportImage, int> mediaIndex,
        int width, int height, int top, int right, int bottom, int left)
    {
        var sb = new StringBuilder(Header);
        sb.Append("<w:document xmlns:w=\"").Append(W).Append("\" xmlns:r=\"").Append(OfficeRel).Append("\"")
            .Append(" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"")
            .Append(" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"")
            .Append(" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>");
        int drawing = 0;
        bool any = false;
        for (int p = 0; p < document.Pages.Count; p++)
        {
            bool pageBreak = p > 0;
            var blocks = document.Pages[p].Blocks;
            if (blocks.Count == 0 && pageBreak) sb.Append("<w:p><w:pPr><w:pageBreakBefore/></w:pPr></w:p>");
            foreach (var block in blocks)
            {
                any = true;
                switch (block)
                {
                    case ExportParagraph paragraph:
                        Paragraph(sb, paragraph, document.BodySize, pageBreak);
                        break;
                    case ExportTable table:
                        if (pageBreak) sb.Append("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>");
                        Table(sb, table, contentTwips);
                        break;
                    case ExportPicture picture:
                        if (!mediaIndex.TryGetValue(picture.Image, out int number))
                        {
                            media.Add(picture.Image);
                            mediaIndex[picture.Image] = number = media.Count;
                        }
                        Picture(sb, picture, number, ++drawing, contentTwips, pageBreak);
                        break;
                }
                pageBreak = false;
            }
        }
        if (!any) sb.Append("<w:p/>");
        sb.Append("<w:sectPr><w:pgSz w:w=\"").Append(I(width)).Append("\" w:h=\"").Append(I(height)).Append('"');
        if (width > height) sb.Append(" w:orient=\"landscape\"");
        sb.Append("/><w:pgMar w:top=\"").Append(I(top)).Append("\" w:right=\"").Append(I(right)).Append("\" w:bottom=\"").Append(I(bottom))
            .Append("\" w:left=\"").Append(I(left)).Append("\" w:header=\"").Append(I(Math.Min(top, 720) / 2)).Append("\" w:footer=\"").Append(I(Math.Min(bottom, 720) / 2))
            .Append("\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>");
        return sb.ToString();
    }

    private static void Paragraph(StringBuilder sb, ExportParagraph paragraph, double body, bool pageBreak)
    {
        sb.Append("<w:p><w:pPr>");
        if (paragraph.Heading > 0) sb.Append("<w:pStyle w:val=\"Heading").Append(I(paragraph.Heading)).Append("\"/>");
        else if (paragraph.Item is not null) sb.Append("<w:pStyle w:val=\"ListParagraph\"/>");
        if (pageBreak) sb.Append("<w:pageBreakBefore/>");
        if (paragraph.Item is { } item) sb.Append("<w:numPr><w:ilvl w:val=\"").Append(I(item.Level)).Append("\"/><w:numId w:val=\"").Append(I(item.ListId)).Append("\"/></w:numPr>");
        sb.Append("</w:pPr>");
        foreach (var run in paragraph.Runs) Run(sb, run, paragraph.Heading == 0, body);
        sb.Append("</w:p>");
    }

    private static void Run(StringBuilder sb, ExportRun run, bool style, double body)
    {
        var props = new StringBuilder();
        if (style && run.Bold) props.Append("<w:b/>");
        if (style && run.Italic) props.Append("<w:i/>");
        if (style && Math.Abs(run.Size - body) > 0.6) props.Append("<w:sz w:val=\"").Append(I((long)Math.Round(run.Size * 2))).Append("\"/><w:szCs w:val=\"").Append(I((long)Math.Round(run.Size * 2))).Append("\"/>");
        sb.Append("<w:r>");
        if (props.Length > 0) sb.Append("<w:rPr>").Append(props).Append("</w:rPr>");
        string[] pieces = run.Text.Replace("\r", "").Split('\t');
        for (int i = 0; i < pieces.Length; i++)
        {
            if (i > 0) sb.Append("<w:tab/>");
            if (pieces[i].Length > 0) sb.Append("<w:t xml:space=\"preserve\">").Append(Escape(pieces[i])).Append("</w:t>");
        }
        sb.Append("</w:r>");
    }

    private static void Table(StringBuilder sb, ExportTable table, int contentTwips)
    {
        int columns = table.Columns;
        if (columns == 0) return;
        var widths = new int[columns];
        double total = table.Widths?.Sum() ?? 0;
        for (int c = 0; c < columns; c++)
            widths[c] = (int)Math.Max(120, total > 0 ? table.Widths![c] / total * contentTwips : (double)contentTwips / columns);

        sb.Append("<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"").Append(I(widths.Sum())).Append("\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/></w:tblPr><w:tblGrid>");
        foreach (int w in widths) sb.Append("<w:gridCol w:w=\"").Append(I(w)).Append("\"/>");
        sb.Append("</w:tblGrid>");
        foreach (var row in table.Rows)
        {
            sb.Append("<w:tr>");
            for (int c = 0; c < columns; c++)
            {
                sb.Append("<w:tc><w:tcPr><w:tcW w:w=\"").Append(I(widths[c])).Append("\" w:type=\"dxa\"/></w:tcPr><w:p>");
                if (row[c].Length > 0) sb.Append("<w:r><w:t xml:space=\"preserve\">").Append(Escape(row[c])).Append("</w:t></w:r>");
                sb.Append("</w:p></w:tc>");
            }
            sb.Append("</w:tr>");
        }
        sb.Append("</w:tbl><w:p><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:p>");
    }

    private static void Picture(StringBuilder sb, ExportPicture picture, int media, int drawing, int contentTwips, bool pageBreak)
    {
        long cx = Emu(picture.Bounds.Width), cy = Emu(picture.Bounds.Height);
        long limit = contentTwips * 635L;
        if (cx > limit)
        {
            cy = Math.Max(1, cy * limit / cx);
            cx = limit;
        }
        string size = $"cx=\"{I(cx)}\" cy=\"{I(cy)}\"", name = ExportText.Image(drawing);
        sb.Append("<w:p>");
        if (pageBreak) sb.Append("<w:pPr><w:pageBreakBefore/></w:pPr>");
        sb.Append("<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent ").Append(size).Append("/>")
            .Append("<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/><wp:docPr id=\"").Append(I(drawing)).Append("\" name=\"").Append(name).Append("\" descr=\"").Append(name).Append("\"/>")
            .Append("<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>")
            .Append("<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>")
            .Append("<pic:nvPicPr><pic:cNvPr id=\"").Append(I(drawing)).Append("\" name=\"image").Append(I(media)).Append('.').Append(picture.Image.Extension).Append("\"/><pic:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></pic:cNvPicPr></pic:nvPicPr>")
            .Append("<pic:blipFill><a:blip r:embed=\"rId").Append(I(media + 2)).Append("\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>")
            .Append("<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext ").Append(size).Append("/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>")
            .Append("</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>");
    }

    private static string Styles(double body)
    {
        var sb = new StringBuilder(Header);
        sb.Append("<w:styles xmlns:w=\"").Append(W).Append("\"><w:docDefaults><w:rPrDefault><w:rPr>")
            .Append("<w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/>")
            .Append("<w:sz w:val=\"").Append(I((long)Math.Round(body * 2))).Append("\"/><w:szCs w:val=\"").Append(I((long)Math.Round(body * 2))).Append("\"/>")
            .Append("</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"259\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>")
            .Append("<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>");
        double[] scale = [2.0, 1.6, 1.35, 1.2, 1.1, 1.0];
        for (int level = 1; level <= 6; level++)
        {
            sb.Append("<w:style w:type=\"paragraph\" w:styleId=\"Heading").Append(I(level)).Append("\"><w:name w:val=\"heading ").Append(I(level)).Append("\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>")
                .Append("<w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"80\"/><w:outlineLvl w:val=\"").Append(I(level - 1)).Append("\"/></w:pPr>")
                .Append("<w:rPr><w:b/><w:sz w:val=\"").Append(I((long)Math.Round(body * scale[level - 1] * 2))).Append("\"/><w:szCs w:val=\"").Append(I((long)Math.Round(body * scale[level - 1] * 2))).Append("\"/></w:rPr></w:style>");
        }
        sb.Append("<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/><w:pPr><w:spacing w:after=\"40\"/><w:ind w:left=\"720\"/></w:pPr></w:style>")
            .Append("<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>")
            .Append("<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:basedOn w:val=\"TableNormal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr>")
            .Append("<w:tblPr><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/></w:tblBorders></w:tblPr></w:style>")
            .Append("</w:styles>");
        return sb.ToString();
    }

    // One abstract list for bullets and one for numbers; each list of the document is a num of its own, so numbering restarts.
    private static string Numbering(ExportDocument document)
    {
        var sb = new StringBuilder(Header);
        sb.Append("<w:numbering xmlns:w=\"").Append(W).Append("\">");
        string[] bullets = ["•", "◦", "▪", "•"];
        for (int kind = 0; kind < 2; kind++)
        {
            sb.Append("<w:abstractNum w:abstractNumId=\"").Append(I(kind)).Append("\"><w:multiLevelType w:val=\"hybridMultilevel\"/>");
            for (int level = 0; level < 4; level++)
            {
                sb.Append("<w:lvl w:ilvl=\"").Append(I(level)).Append("\"><w:start w:val=\"1\"/><w:numFmt w:val=\"").Append(kind == 0 ? "bullet" : "decimal")
                    .Append("\"/><w:lvlText w:val=\"").Append(kind == 0 ? bullets[level] : $"%{level + 1}.").Append("\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"")
                    .Append(I(720 + 360 * level)).Append("\" w:hanging=\"360\"/></w:pPr></w:lvl>");
            }
            sb.Append("</w:abstractNum>");
        }
        var seen = new HashSet<int>();
        foreach (var item in document.Pages.SelectMany(p => p.Blocks).OfType<ExportParagraph>().Select(p => p.Item).OfType<ExportListItem>())
        {
            if (!seen.Add(item.ListId)) continue;
            sb.Append("<w:num w:numId=\"").Append(I(item.ListId)).Append("\"><w:abstractNumId w:val=\"").Append(item.Ordered ? "1" : "0").Append("\"/>");
            if (item.Ordered) sb.Append("<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"").Append(I(Math.Max(1, item.Number))).Append("\"/></w:lvlOverride>");
            sb.Append("</w:num>");
        }
        sb.Append("</w:numbering>");
        return sb.ToString();
    }

    internal static (int Width, int Height) PaperTwips(ExportDocument document)
    {
        if (document.Pages.Count == 0 || !(document.Pages[0].Width > 0) || !(document.Pages[0].Height > 0)) return (12240, 15840);
        return (Math.Clamp((int)Math.Round(document.Pages[0].Width * 20), MinTwips, MaxTwips), Math.Clamp((int)Math.Round(document.Pages[0].Height * 20), MinTwips, MaxTwips));
    }

    // What the content leaves free on every page, kept between a quarter inch and two inches.
    internal static (int Top, int Right, int Bottom, int Left) MarginsTwips(ExportDocument document, int width, int height)
    {
        var boxes = document.Pages.SelectMany(p => p.Blocks.Select(b => (Page: p, b.Bounds))).ToList();
        if (boxes.Count == 0) return (1440, 1440, 1440, 1440);
        int Clamp(double points, int limit) => Math.Clamp((int)Math.Round(points * 20), 360, Math.Max(360, Math.Min(2880, limit)));
        int left = Clamp(boxes.Min(b => b.Bounds.X), width / 3);
        int top = Clamp(boxes.Min(b => b.Bounds.Y), height / 3);
        int right = Clamp(boxes.Min(b => b.Page.Width - b.Bounds.X - b.Bounds.Width), width / 3);
        int bottom = Clamp(boxes.Min(b => b.Page.Height - b.Bounds.Y - b.Bounds.Height), height / 3);
        return (top, right, bottom, left);
    }
}
