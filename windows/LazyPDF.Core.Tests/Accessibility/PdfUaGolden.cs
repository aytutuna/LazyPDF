using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// One line of input is "<op> <case>" (the format is at the top of pdfua-input.txt): the issues the PDF/UA check finds in a file made from the
// name, and what marking it does. The files are made here from the names; the texts are English whatever the machine's language is.
internal static class PdfUaGolden
{
    public static string Run(string input)
    {
        var culture = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        Loc.Table = new Dictionary<string, string>();
        try
        {
            var output = new StringBuilder();
            foreach (string line in input.Split('\n'))
            {
                if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
                string[] words = line.Split(' ');
                output.Append("> ").Append(line).Append('\n');
                foreach (string result in Op(words[0], words[1])) output.Append("< ").Append(result).Append('\n');
            }
            return output.ToString();
        }
        finally
        {
            Loc.Table = null;
            CultureInfo.CurrentCulture = culture;
        }
    }

    private static IEnumerable<string> Op(string op, string name)
    {
        switch (op)
        {
            case "check":
                return Lines(PdfUaKit.Check(Case(name)));
            case "mark":
                using (var document = PdfDocument.Open(Case(name)))
                {
                    var result = PdfUaValidator.Mark(document, PdfUaKit.Date);
                    using var saved = PdfDocument.Open(document.SaveRewrite());
                    return [$"marked {result.Marked.ToString().ToLowerInvariant()}", .. Lines(result.Blocking), $"after {PdfUaValidator.Validate(saved).Issues.Count}"];
                }
            default:
                return [$"unknown op {op}"];
        }
    }

    private static IEnumerable<string> Lines(PdfUaReport report) =>
        [$"issues {report.Issues.Count} truncated {report.Truncated.ToString().ToLowerInvariant()}",
            .. report.Issues.Select(i => $"  {i.Condition} | {i.Clause} | {i.Where} | {i.Message}")];

    private static byte[] Case(string name)
    {
        switch (name)
        {
            case "compliant":
                return PdfUaKit.Build();
            case "unmarked":
                return PdfUaKit.Build(xmp: PdfUaKit.Packet(ua: false), viewer: "");
            case "no-metadata":
                return PdfUaKit.Build(xmp: "", viewer: "");
            case "no-title":
                return PdfUaKit.Build(xmp: PdfUaKit.Packet(ua: false, title: false), viewer: "", info: "<</Creator (Test)>>");
            case "untagged":
                return PdfUaKit.Build(markInfo: "", tree: false);
            case "structure":
                return PdfUaKit.Build(edit: o =>
                {
                    o[9] = "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R /RoleMap <</P /Span /A /B /B /A>>>>";
                    o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R 13 0 R 14 0 R 15 0 R 16 0 R 17 0 R 18 0 R 19 0 R]>>";
                    o[11] = "<</Type /StructElem /S /Figure /P 10 0 R /Pg 3 0 R /K 0>>";
                    o[13] = "<</Type /StructElem /S /Table /P 10 0 R /K 20 0 R>>";
                    o[20] = "<</Type /StructElem /S /TD /P 13 0 R>>";
                    o[14] = "<</Type /StructElem /S /L /P 10 0 R /K 21 0 R>>";
                    o[21] = "<</Type /StructElem /S /Lbl /P 14 0 R>>";
                    o[15] = "<</Type /StructElem /S /H2 /P 10 0 R>>";
                    o[16] = "<</Type /StructElem /S /H /P 10 0 R>>";
                    o[17] = "<</Type /StructElem /S /A /P 10 0 R>>";
                    o[18] = "<</Type /StructElem /S /Weird /P 10 0 R>>";
                    o[19] = "<</Type /StructElem /S /Note /P 10 0 R /Lang (x y)>>";
                });
            case "catalog":
                return PdfUaKit.Build(
                    markInfo: "/MarkInfo <</Marked true /Suspects true>>", lang: "/Lang (xx_y)", viewer: "",
                    xmp: PdfUaKit.Packet(ua: false, title: false), page: "/Annots [14 0 R]",
                    catalog: "/OCProperties <</OCGs [] /D <</AS []>>>> /NeedsRendering true /AcroForm <</Fields [] /XFA []>> /Names <</EmbeddedFiles <</Names [(a) 13 0 R]>>>>",
                    content: PdfUaKit.Figure + " 1 0 0 rg 0 0 5 5 re f /Artifact BMC /Figure <</MCID 0>> BDC 0 0 1 rg 0 0 5 5 re f EMC EMC",
                    resources: "/XObject <</X1 15 0 R /X2 16 0 R>>",
                    extra: pdf =>
                    {
                        pdf.Obj(13, "<</Type /Filespec /F (a.txt)>>");
                        pdf.Obj(14, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10]>>");
                        pdf.Stream(15, "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Ref <</F (x.pdf) /Page 0>>", "");
                        pdf.Stream(16, "/Type /XObject /Subtype /PS", "");
                    });
            case "text":
                return PdfUaKit.Build(content: "/P <</MCID 0>> BDC BT /F1 12 Tf 20 100 Td (A) Tj ET EMC", resources: "/Font <</F1 13 0 R>>",
                    edit: o => o[11] = "<</Type /StructElem /S /P /P 10 0 R /Pg 3 0 R /K 0>>",
                    extra: pdf => pdf.Obj(13, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /Differences [65 /zzunknown]>>>>"));
            default:
                throw new ArgumentException($"unknown case {name}");
        }
    }
}
