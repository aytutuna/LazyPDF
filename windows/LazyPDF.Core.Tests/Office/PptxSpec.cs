using System.Globalization;
using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;

namespace LazyPDF.Core.Tests;

// Reads pptx-input.txt, the cases of Tests/Fixtures/golden/office-pptx, into packages and dumps the pages laid out from them.
// To be mirrored by Tests/LazyPDFKitTests/Office, which reads the same file.
//
//   > name                       starts a case
//   @presentation                the lines that follow are the inside of the presentation element; without it a 720 x 540 pt
//                                slide and the usual default text style (18 pt, tx1) are used
//   @slide1, @slide2 ... [layout=N] [attribute=value ...]   the inside of a sld element, on layout N (1 if not said); the
//                                other words are attributes of the element (show=0, showMasterSp=0). The slide order is the number
//   @layout1 ... [master=N] [attributes]    the inside of a sldLayout element; without a layout1 an empty one is made
//   @master1 ... [theme=0]       the inside of a sldMaster element; without a master1 an empty one is made. It points at the theme
//   @theme                       the inside of an a:theme element; nothing after it stands for a standard Office theme
//   @rels part                   extra relationship elements for the part (slide1, layout1, master1), for pictures
//   @part path                   a whole part, written out
internal static class PptxSpec
{
    private const string P = "http://schemas.openxmlformats.org/presentationml/2006/main";
    private const string A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    private const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string Rel = R + "/";
    private const string Ml = "application/vnd.openxmlformats-officedocument.presentationml.";

    private const string StandardPresentation =
        "<p:sldSz cx=\"9144000\" cy=\"6858000\"/><p:defaultTextStyle><a:lvl1pPr marL=\"0\"><a:defRPr sz=\"1800\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl1pPr>" +
        "<a:lvl2pPr marL=\"457200\"><a:defRPr sz=\"1800\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl2pPr></p:defaultTextStyle>";

    private const string StandardTheme =
        "<a:themeElements><a:clrScheme name=\"Office\"><a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1><a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>" +
        "<a:dk2><a:srgbClr val=\"1F497D\"/></a:dk2><a:lt2><a:srgbClr val=\"EEECE1\"/></a:lt2><a:accent1><a:srgbClr val=\"4F81BD\"/></a:accent1><a:accent2><a:srgbClr val=\"C0504D\"/></a:accent2>" +
        "<a:accent3><a:srgbClr val=\"9BBB59\"/></a:accent3><a:accent4><a:srgbClr val=\"8064A2\"/></a:accent4><a:accent5><a:srgbClr val=\"4BACC6\"/></a:accent5><a:accent6><a:srgbClr val=\"F79646\"/></a:accent6>" +
        "<a:hlink><a:srgbClr val=\"0000FF\"/></a:hlink><a:folHlink><a:srgbClr val=\"800080\"/></a:folHlink></a:clrScheme>" +
        "<a:fontScheme name=\"Office\"><a:majorFont><a:latin typeface=\"Cambria\"/></a:majorFont><a:minorFont><a:latin typeface=\"Calibri\"/></a:minorFont></a:fontScheme>" +
        "<a:fmtScheme name=\"Office\"><a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"><a:tint val=\"50000\"/></a:schemeClr></a:solidFill>" +
        "<a:gradFill><a:gsLst><a:gs pos=\"0\"><a:schemeClr val=\"phClr\"><a:shade val=\"50000\"/></a:schemeClr></a:gs><a:gs pos=\"100000\"><a:schemeClr val=\"phClr\"/></a:gs></a:gsLst></a:gradFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements>";

    private sealed class Part(string[] words)
    {
        public string Kind { get; } = words[0];
        public Dictionary<string, string> Arguments { get; } = words.Skip(1).Select(w => w.Split('=', 2)).ToDictionary(w => w[0], w => w.Length > 1 ? w[1] : "");
        public StringBuilder Text { get; } = new();
    }

    public static List<(string Name, byte[] Package)> Read(string input)
    {
        var cases = new List<(string, byte[])>();
        string? name = null;
        var parts = new List<Part>();

        void Flush()
        {
            if (name is not null) cases.Add((name, Package(parts)));
            parts = [];
        }

        foreach (string line in input.Split('\n'))
        {
            if (line.StartsWith("> ", StringComparison.Ordinal))
            {
                Flush();
                name = line[2..];
            }
            else if (line.StartsWith("@", StringComparison.Ordinal))
            {
                parts.Add(new Part(line[1..].Split(' ', StringSplitOptions.RemoveEmptyEntries)));
            }
            else if (parts.Count > 0 && !line.StartsWith("# ", StringComparison.Ordinal))
            {
                parts[^1].Text.Append(line).Append('\n');
            }
        }
        Flush();
        return cases;
    }

    /// <summary>The package of a single case written in the format above, without the line that starts it.</summary>
    public static byte[] One(string text) => Read("> case\n" + text)[0].Package;

    private static byte[] Package(List<Part> parts)
    {
        var entries = new List<ExportZipEntry>();
        var types = new StringBuilder();
        var extra = new Dictionary<string, string>();
        foreach (var part in parts.Where(p => p.Kind == "rels")) extra[part.Arguments.Keys.First()] = part.Text.ToString();

        void Add(string path, string xml) => entries.Add(new ExportZipEntry(path, Encoding.UTF8.GetBytes(xml)));

        string Wrapped(string root, string attributes, string inside) =>
            $"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><{root} xmlns:p=\"{P}\" xmlns:a=\"{A}\" xmlns:r=\"{R}\"{attributes}>{inside}</{root}>";

        string Attributes(Part part) =>
            string.Concat(part.Arguments.Where(a => a.Key is not ("layout" or "master" or "theme")).Select(a => $" {a.Key}=\"{a.Value}\""));

        void Rels(string path, string key, string list)
        {
            string folder = path[..path.LastIndexOf('/')], file = path[(path.LastIndexOf('/') + 1)..];
            Add($"{folder}/_rels/{file}.rels",
                $"<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">{list}{extra.GetValueOrDefault(key)}</Relationships>");
        }

        var slides = parts.Where(p => p.Kind.StartsWith("slide", StringComparison.Ordinal)).OrderBy(p => int.Parse(p.Kind[5..], CultureInfo.InvariantCulture)).ToList();
        var layouts = parts.Where(p => p.Kind.StartsWith("layout", StringComparison.Ordinal)).ToList();
        var masters = parts.Where(p => p.Kind.StartsWith("master", StringComparison.Ordinal)).ToList();
        if (layouts.All(l => l.Kind != "layout1")) layouts.Add(new Part(["layout1"]));
        if (masters.All(m => m.Kind != "master1")) masters.Add(new Part(["master1"]));
        var theme = parts.FirstOrDefault(p => p.Kind == "theme");
        var presentation = parts.FirstOrDefault(p => p.Kind == "presentation");

        var ids = new StringBuilder();
        var presentationRels = new StringBuilder();
        for (int i = 0; i < slides.Count; i++)
        {
            string n = slides[i].Kind[5..];
            ids.Append($"<p:sldId id=\"{256 + i}\" r:id=\"rIdS{n}\"/>");
            presentationRels.Append($"<Relationship Id=\"rIdS{n}\" Type=\"{Rel}slide\" Target=\"slides/slide{n}.xml\"/>");
            Add($"ppt/slides/slide{n}.xml", Wrapped("p:sld", Attributes(slides[i]), slides[i].Text.ToString()));
            Rels($"ppt/slides/slide{n}.xml", slides[i].Kind, $"<Relationship Id=\"rIdL\" Type=\"{Rel}slideLayout\" Target=\"../slideLayouts/slideLayout{slides[i].Arguments.GetValueOrDefault("layout", "1")}.xml\"/>");
            types.Append($"<Override PartName=\"/ppt/slides/slide{n}.xml\" ContentType=\"{Ml}slide+xml\"/>");
        }
        foreach (var layout in layouts)
        {
            string n = layout.Kind[6..];
            Add($"ppt/slideLayouts/slideLayout{n}.xml", Wrapped("p:sldLayout", Attributes(layout), layout.Text.Length > 0 ? layout.Text.ToString() : "<p:cSld><p:spTree/></p:cSld>"));
            Rels($"ppt/slideLayouts/slideLayout{n}.xml", layout.Kind, $"<Relationship Id=\"rIdM\" Type=\"{Rel}slideMaster\" Target=\"../slideMasters/slideMaster{layout.Arguments.GetValueOrDefault("master", "1")}.xml\"/>");
            types.Append($"<Override PartName=\"/ppt/slideLayouts/slideLayout{n}.xml\" ContentType=\"{Ml}slideLayout+xml\"/>");
        }
        foreach (var master in masters)
        {
            string n = master.Kind[6..];
            Add($"ppt/slideMasters/slideMaster{n}.xml", Wrapped("p:sldMaster", Attributes(master), master.Text.Length > 0 ? master.Text.ToString() : "<p:cSld><p:spTree/></p:cSld>"));
            Rels($"ppt/slideMasters/slideMaster{n}.xml", master.Kind, $"<Relationship Id=\"rIdT\" Type=\"{Rel}theme\" Target=\"../theme/theme1.xml\"/>");
            types.Append($"<Override PartName=\"/ppt/slideMasters/slideMaster{n}.xml\" ContentType=\"{Ml}slideMaster+xml\"/>");
        }
        Add("ppt/theme/theme1.xml", Wrapped("a:theme", "", theme is null || theme.Text.ToString().Trim().Length == 0 ? StandardTheme : theme.Text.ToString()));
        types.Append("<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>");
        foreach (var part in parts.Where(p => p.Kind == "part")) Add(part.Arguments.Keys.First(), part.Text.ToString().TrimEnd('\n'));

        Add("ppt/presentation.xml", Wrapped("p:presentation", presentation is null ? "" : Attributes(presentation),
            $"<p:sldIdLst>{ids}</p:sldIdLst>" + (presentation is null || presentation.Text.ToString().Trim().Length == 0 ? StandardPresentation : presentation.Text.ToString())));
        Rels("ppt/presentation.xml", "presentation", presentationRels.ToString());
        Add("[Content_Types].xml",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
            $"<Override PartName=\"/ppt/presentation.xml\" ContentType=\"{Ml}presentation.main+xml\"/>{types}</Types>");
        Add("_rels/.rels",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
            $"<Relationship Id=\"rId1\" Type=\"{Rel}officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>");
        return ExportZip.Make(entries);
    }

    private static string Num(double value) => (Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100 + 0.0).ToString("0.00", CultureInfo.InvariantCulture);

    public static string Dump(LayoutResult layout)
    {
        var output = new StringBuilder();
        for (int i = 0; i < layout.Pages.Count; i++)
        {
            var page = layout.Pages[i];
            output.Append($"page {i + 1} {Num(page.Width)} {Num(page.Height)}\n");
            foreach (var box in page.Boxes)
            {
                switch (box)
                {
                    case PlacedText t:
                        output.Append($"text {Num(t.X)} {Num(t.Baseline)} {t.Family}/{t.Style} {Num(t.Size)} {t.Color:x6} +{Num(t.SpaceExtra)} \"{OfficeLayoutSpec.Escape(t.Text)}\"\n");
                        break;
                    case PlacedRect r:
                        output.Append($"rect {Num(r.X)} {Num(r.Y)} {Num(r.Width)} {Num(r.Height)} {r.Color:x6}\n");
                        break;
                    case PlacedImage m:
                        output.Append($"image {Num(m.X)} {Num(m.Y)} {Num(m.Width)} {Num(m.Height)} {m.Source.Data.Length} crop {Num(m.Source.CropLeft)} {Num(m.Source.CropTop)} {Num(m.Source.CropRight)} {Num(m.Source.CropBottom)}\n");
                        break;
                }
            }
        }
        foreach (var s in layout.Skipped) output.Append($"skipped {s.Kind} {s.Count}\n");
        return output.ToString();
    }
}
