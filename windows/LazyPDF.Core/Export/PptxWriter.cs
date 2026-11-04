using System.Text;
using static LazyPDF.Core.ExportXml;

namespace LazyPDF.Core;

/// <summary>
/// The PowerPoint file (.pptx) of an <see cref="ExportDocument"/>: a slide for each page, sized as
/// the first page, with its pictures in place and every text line in a box of its own at its
/// position, so the slide looks like the page and each line can still be edited.
/// </summary>
public static class PptxWriter
{
    private const string A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    private const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string P = "http://schemas.openxmlformats.org/presentationml/2006/main";
    private const string RelNs = "http://schemas.openxmlformats.org/package/2006/relationships";
    private const long MinSlide = 914400, MaxSlide = 51206400;

    // Slides are held as strings until the package is made, then copied to bytes; a picture adds a relationship to its slide besides its markup.
    private const long MaxSlideChars = 1L << 27;
    private const int RelChars = 256;
    private const int FixedEntries = 9;

    public static byte[] Make(ExportDocument document)
    {
        var first = document.Pages.Count > 0 ? document.Pages[0] : null;
        long width = first is { Width: > 0 } ? Math.Clamp(Emu(first.Width), MinSlide, MaxSlide) : 9144000;
        long height = first is { Height: > 0 } ? Math.Clamp(Emu(first.Height), MinSlide, MaxSlide) : 6858000;

        var media = new List<ExportImage>();
        var mediaIndex = new Dictionary<ExportImage, int>(ReferenceEqualityComparer.Instance);
        ExportZip.CheckCount(FixedEntries + 2L * document.Pages.Count);
        var slides = new List<(string Xml, List<int> Images)>();
        long held = 0;
        foreach (var page in document.Pages)
        {
            slides.Add(Slide(page, width, height, media, mediaIndex, held));
            held += slides[^1].Xml.Length + RelChars * (long)slides[^1].Images.Count;
        }
        ExportZip.CheckCount(FixedEntries + 2L * slides.Count + media.Count);

        var types = new StringBuilder(Header);
        types.Append("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">")
            .Append("<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>");
        if (media.Any(m => m.IsJpeg)) types.Append("<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>");
        if (media.Any(m => !m.IsJpeg)) types.Append("<Default Extension=\"png\" ContentType=\"image/png\"/>");
        types.Append("<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>")
            .Append("<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>")
            .Append("<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>")
            .Append("<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>");
        for (int i = 0; i < slides.Count; i++)
            types.Append("<Override PartName=\"/ppt/slides/slide").Append(I(i + 1)).Append(".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>");
        types.Append("</Types>");

        var presentation = new StringBuilder(Header);
        presentation.Append("<p:presentation xmlns:a=\"").Append(A).Append("\" xmlns:r=\"").Append(R).Append("\" xmlns:p=\"").Append(P)
            .Append("\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>");
        var presentationRels = new StringBuilder(Header);
        presentationRels.Append("<Relationships xmlns=\"").Append(RelNs).Append("\"><Relationship Id=\"rId1\" Type=\"").Append(R).Append("/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>")
            .Append("<Relationship Id=\"rId2\" Type=\"").Append(R).Append("/theme\" Target=\"theme/theme1.xml\"/>");
        if (slides.Count > 0) presentation.Append("<p:sldIdLst>");
        for (int i = 0; i < slides.Count; i++)
        {
            presentation.Append("<p:sldId id=\"").Append(I(256 + i)).Append("\" r:id=\"rId").Append(I(i + 3)).Append("\"/>");
            presentationRels.Append("<Relationship Id=\"rId").Append(I(i + 3)).Append("\" Type=\"").Append(R).Append("/slide\" Target=\"slides/slide").Append(I(i + 1)).Append(".xml\"/>");
        }
        if (slides.Count > 0) presentation.Append("</p:sldIdLst>");
        presentation.Append("<p:sldSz cx=\"").Append(I(width)).Append("\" cy=\"").Append(I(height)).Append("\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>");
        presentationRels.Append("</Relationships>");

        var entries = new List<ExportZipEntry>
        {
            new("[Content_Types].xml", Utf8(types.ToString())),
            new("_rels/.rels", Utf8(Header + "<Relationships xmlns=\"" + RelNs + "\"><Relationship Id=\"rId1\" Type=\"" + R + "/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")),
            new("ppt/presentation.xml", Utf8(presentation.ToString())),
            new("ppt/_rels/presentation.xml.rels", Utf8(presentationRels.ToString())),
            new("ppt/slideMasters/slideMaster1.xml", Utf8(Master)),
            new("ppt/slideMasters/_rels/slideMaster1.xml.rels", Utf8(Header + "<Relationships xmlns=\"" + RelNs + "\"><Relationship Id=\"rId1\" Type=\"" + R + "/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"" + R + "/theme\" Target=\"../theme/theme1.xml\"/></Relationships>")),
            new("ppt/slideLayouts/slideLayout1.xml", Utf8(Layout)),
            new("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Utf8(Header + "<Relationships xmlns=\"" + RelNs + "\"><Relationship Id=\"rId1\" Type=\"" + R + "/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>")),
            new("ppt/theme/theme1.xml", Utf8(Theme)),
        };
        for (int i = 0; i < slides.Count; i++)
        {
            var rels = new StringBuilder(Header);
            rels.Append("<Relationships xmlns=\"").Append(RelNs).Append("\"><Relationship Id=\"rId1\" Type=\"").Append(R).Append("/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>");
            for (int m = 0; m < slides[i].Images.Count; m++)
            {
                var image = media[slides[i].Images[m] - 1];
                rels.Append("<Relationship Id=\"rId").Append(I(m + 2)).Append("\" Type=\"").Append(R).Append("/image\" Target=\"../media/image").Append(I(slides[i].Images[m])).Append('.').Append(image.Extension).Append("\"/>");
            }
            rels.Append("</Relationships>");
            entries.Add(new($"ppt/slides/slide{i + 1}.xml", Utf8(slides[i].Xml)));
            entries.Add(new($"ppt/slides/_rels/slide{i + 1}.xml.rels", Utf8(rels.ToString())));
        }
        for (int i = 0; i < media.Count; i++) entries.Add(new($"ppt/media/image{i + 1}.{media[i].Extension}", media[i].Data));
        return ExportZip.Make(entries);
    }

    private static (string Xml, List<int> Images) Slide(ExportPage page, long width, long height, List<ExportImage> media, Dictionary<ExportImage, int> mediaIndex, long held)
    {
        double scale = Math.Min(width / (page.Width * EmuPerPoint), height / (page.Height * EmuPerPoint));
        if (!(scale > 0) || double.IsInfinity(scale)) scale = 1;
        double offsetX = (width - page.Width * EmuPerPoint * scale) / 2, offsetY = (height - page.Height * EmuPerPoint * scale) / 2;
        string Frame(DisplayRect r, double grow = 0) =>
            $"<a:xfrm><a:off x=\"{I((long)Math.Round(offsetX + r.X * EmuPerPoint * scale))}\" y=\"{I((long)Math.Round(offsetY + r.Y * EmuPerPoint * scale))}\"/>"
            + $"<a:ext cx=\"{I(Math.Max(1, (long)Math.Round((r.Width + grow) * EmuPerPoint * scale)))}\" cy=\"{I(Math.Max(1, (long)Math.Round(r.Height * EmuPerPoint * scale)))}\"/></a:xfrm>";

        var images = new List<int>();
        var sb = new StringBuilder(Header);
        sb.Append("<p:sld xmlns:a=\"").Append(A).Append("\" xmlns:r=\"").Append(R).Append("\" xmlns:p=\"").Append(P)
            .Append("\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>");
        int id = 1;
        foreach (var picture in page.Pictures)
        {
            CheckLength(sb, held + RelChars, MaxSlideChars);
            if (!mediaIndex.TryGetValue(picture.Image, out int number))
            {
                media.Add(picture.Image);
                mediaIndex[picture.Image] = number = media.Count;
            }
            images.Add(number);
            string name = ExportText.Image(images.Count);
            sb.Append("<p:pic><p:nvPicPr><p:cNvPr id=\"").Append(I(++id)).Append("\" name=\"").Append(name).Append("\" descr=\"").Append(name)
                .Append("\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId").Append(I(images.Count + 1))
                .Append("\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>").Append(Frame(picture.Bounds)).Append("<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>");
        }
        foreach (var line in page.Lines)
        {
            CheckLength(sb, held, MaxSlideChars);
            sb.Append("<p:sp><p:nvSpPr><p:cNvPr id=\"").Append(I(++id)).Append("\" name=\"Text ").Append(I(id)).Append("\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr>")
                .Append(Frame(line.Bounds, line.Bounds.Height * 0.5)).Append("<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>")
                .Append("<p:txBody><a:bodyPr wrap=\"none\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" rtlCol=\"0\" anchor=\"t\"><a:noAutofit/></a:bodyPr><a:lstStyle/><a:p>");
            foreach (var run in line.Runs)
            {
                int size = (int)Math.Clamp(Math.Round(run.Size * scale * 100), 100, 400000);
                sb.Append("<a:r><a:rPr sz=\"").Append(I(size)).Append('"');
                if (run.Bold) sb.Append(" b=\"1\"");
                if (run.Italic) sb.Append(" i=\"1\"");
                sb.Append(" dirty=\"0\"/><a:t>").Append(Escape(run.Text.Replace('\t', ' '))).Append("</a:t></a:r>");
            }
            sb.Append("</a:p></p:txBody></p:sp>");
        }
        sb.Append("</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>");
        CheckLength(sb, held, MaxSlideChars);
        return (sb.ToString(), images);
    }

    private const string Empty = "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>";

    private const string Master = Header + "<p:sldMaster xmlns:a=\"" + A + "\" xmlns:r=\"" + R + "\" xmlns:p=\"" + P + "\">" + Empty
        + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>";

    private const string Layout = Header + "<p:sldLayout xmlns:a=\"" + A + "\" xmlns:r=\"" + R + "\" xmlns:p=\"" + P + "\" type=\"blank\" preserve=\"1\">"
        + "<p:cSld name=\"Blank\"><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>";

    private const string Theme = Header + "<a:theme xmlns:a=\"" + A + "\" name=\"Office\"><a:themeElements><a:clrScheme name=\"Office\">"
        + "<a:dk1><a:srgbClr val=\"000000\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1><a:dk2><a:srgbClr val=\"44546A\"/></a:dk2><a:lt2><a:srgbClr val=\"E7E6E6\"/></a:lt2>"
        + "<a:accent1><a:srgbClr val=\"4472C4\"/></a:accent1><a:accent2><a:srgbClr val=\"ED7D31\"/></a:accent2><a:accent3><a:srgbClr val=\"A5A5A5\"/></a:accent3><a:accent4><a:srgbClr val=\"FFC000\"/></a:accent4>"
        + "<a:accent5><a:srgbClr val=\"5B9BD5\"/></a:accent5><a:accent6><a:srgbClr val=\"70AD47\"/></a:accent6><a:hlink><a:srgbClr val=\"0563C1\"/></a:hlink><a:folHlink><a:srgbClr val=\"954F72\"/></a:folHlink></a:clrScheme>"
        + "<a:fontScheme name=\"Office\"><a:majorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
        + "<a:fmtScheme name=\"Office\"><a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst>"
        + "<a:lnStyleLst><a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"19050\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst>"
        + "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
        + "<a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>"
        + "</a:themeElements></a:theme>";
}
