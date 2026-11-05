using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Pages/PagesGolden.swift. One line of input is "<op> <words>" (the format is at the top of
// pages-input.txt): typed page ranges, and whole documents after a page operation. A document is shown as every object of the
// file with the trailer, streams decoded, so that the numbers the importer and the page tree give to new objects are pinned too.
internal static class PagesGolden
{
    public static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            int space = line.IndexOf(' ');
            string op = space < 0 ? line : line[..space];
            string rest = space < 0 ? "" : line[(space + 1)..];
            output.Append("> ").Append(line).Append('\n');
            foreach (string result in Op(op, Encoding.UTF8.GetString(Golden.Unescape(rest)))) output.Append("< ").Append(result).Append('\n');
        }
        return output.ToString();
    }

    private static IEnumerable<string> Op(string op, string rest)
    {
        switch (op)
        {
            case "range": return [Range(rest)];
            case "case": return Case(rest);
            default: return [$"unknown op {op}"];
        }
    }

    // text|page count
    private static string Range(string rest)
    {
        int bar = rest.LastIndexOf('|');
        var result = PageRange.Parse(rest[..bar], int.Parse(rest[(bar + 1)..], CultureInfo.InvariantCulture));
        return result.IsSuccess ? $"pages [{string.Join(",", result.Pages)}]" : $"error {Show(result.Error!.Message)}";
    }

    private static string Show(string text)
    {
        var sb = new StringBuilder();
        foreach (char c in text)
        {
            switch (c)
            {
                case '\\': sb.Append(@"\\"); break;
                case '\n': sb.Append(@"\n"); break;
                case '\r': sb.Append(@"\r"); break;
                case '\t': sb.Append(@"\t"); break;
                default:
                    if (c < 0x20 || c >= 0x7F) sb.Append(@"\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    private static IEnumerable<string> Dump(PdfDocument document)
    {
        yield return $"trailer {document.Trailer}";
        foreach (int number in document.ObjectNumbers)
        {
            string text = document.Get(number) switch
            {
                PdfStream s => $"stream {s.Dictionary} | {Show(Encoding.Latin1.GetString(document.Data(s)))}",
                null => "null",
                var value => value.ToString()!,
            };
            yield return $"{number}: {text}";
        }
    }

    private static IEnumerable<string> Parts(IEnumerable<PdfDocument> parts) =>
        parts.SelectMany((part, i) => Dump(part).Select(line => $"part {i} {line}"));

    // Page 1 has a text field, a note with its popup, links of each kind and a calculation order; page 2 the other widget of a field.
    private static PdfDocument Annotated()
    {
        const string annots = "/Annots [40 0 R 41 0 R 42 0 R 43 0 R 44 0 R 45 0 R 46 0 R 50 0 R]";
        const string form = "/AcroForm <</Fields [50 0 R 52 0 R] /CO [50 0 R] /DA (/Helv 0 Tf 0 g) /DR <</Font <</Helv 60 0 R>>>> /NeedAppearances true>>";
        return PdfDocument.Open(PageImportTests.Source(annots, "/Dests <</five [5 0 R /Fit]>> " + form, pdf => pdf
            .Obj(40, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [5 0 R /Fit]>>")
            .Obj(41, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /GoTo /D [6 0 R /Fit]>>>>")
            .Obj(42, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest /five>>")
            .Obj(43, "<</Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (note) /Popup 44 0 R /P 4 0 R /StructParent 3>>")
            .Obj(44, "<</Type /Annot /Subtype /Popup /Rect [50 50 100 100] /Parent 43 0 R /Open true>>")
            .Obj(45, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /URI /URI (http://example.com)>>>>")
            .Obj(46, "<</Type /Annot /Subtype /Popup /Rect [50 50 100 100] /Parent 99 0 R>>")
            .Obj(50, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Alice) /DA (/Helv 12 Tf 0 g) /Rect [0 0 50 20]>>")
            .Obj(51, "<</Type /Annot /Subtype /Widget /Parent 52 0 R /Rect [0 30 50 50]>>")
            .Obj(52, "<</T (grp) /FT /Tx /V (G) /Kids [51 0 R 53 0 R]>>")
            .Obj(53, "<</Type /Annot /Subtype /Widget /Parent 52 0 R /Rect [0 60 50 80]>>")
            .Obj(60, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"), "/Annots [51 0 R 53 0 R]"));
    }

    // Four pages with an outline, named destinations, links, an open action, labels, threads, fields and actions that share followers.
    private static PdfDocument Linked()
    {
        const int outline = 12;
        int n = PageTestFiles.Free(4) + 20;
        return PageTestFiles.Open(4,
            $"/Outlines {outline} 0 R /OpenAction 70 0 R /PageLabels <</Nums [0 <</S /r>> 2 <</S /D /St 5>>]>> /Threads [{n} 0 R] " +
            "/Dests <</a [5 0 R /Fit] /b [6 0 R /Fit]>> /Names <</Dests <</Names [(c) [5 0 R /Fit] (d) [6 0 R /Fit] (e) <</D [4 0 R /Fit]>>]>>>> " +
            $"/AcroForm <</Fields [{n + 20} 0 R {n + 21} 0 R] /CO [{n + 20} 0 R {n + 21} 0 R]>>",
            pageExtra: i => i switch
            {
                0 => $"/Annots [{n + 10} 0 R {n + 11} 0 R {n + 20} 0 R]",
                1 => $"/Annots [{n + 22} 0 R]",
                2 => $"/Annots [{n + 23} 0 R]",
                _ => "",
            },
            add: pdf =>
            {
                pdf.Obj(outline, $"<</Type /Outlines /First {outline + 1} 0 R /Last {outline + 4} 0 R /Count 4>>");
                pdf.Obj(outline + 1, $"<</Title (One) /Parent {outline} 0 R /Next {outline + 2} 0 R /Dest [4 0 R /Fit]>>");
                pdf.Obj(outline + 2, $"<</Title (Two) /Parent {outline} 0 R /Prev {outline + 1} 0 R /Next {outline + 3} 0 R /Dest [5 0 R /XYZ 0 0 0] /First {outline + 5} 0 R /Last {outline + 5} 0 R /Count 1>>");
                pdf.Obj(outline + 3, $"<</Title (Three) /Parent {outline} 0 R /Prev {outline + 2} 0 R /Next {outline + 4} 0 R /A <</S /GoTo /D [7 0 R /Fit]>>>>");
                pdf.Obj(outline + 4, $"<</Title (Four) /Parent {outline} 0 R /Prev {outline + 3} 0 R /Dest (c)>>");
                pdf.Obj(outline + 5, $"<</Title (Child) /Parent {outline + 2} 0 R /Dest [6 0 R /Fit]>>");
                pdf.Obj(70, "<</S /GoTo /D [5 0 R /Fit] /Next [71 0 R 72 0 R [71 0 R]]>>");
                pdf.Obj(71, "<</S /URI /URI (http://a)>>");
                pdf.Obj(72, "<</S /URI /URI (http://b)>>");
                pdf.Obj(n, $"<</Type /Thread /F {n + 1} 0 R>>");
                pdf.Obj(n + 1, $"<</Type /Bead /T {n} 0 R /N {n + 2} 0 R /V {n + 3} 0 R /P 4 0 R /R [0 0 10 10]>>");
                pdf.Obj(n + 2, $"<</Type /Bead /N {n + 3} 0 R /V {n + 1} 0 R /P 5 0 R /R [0 0 10 10]>>");
                pdf.Obj(n + 3, $"<</Type /Bead /N {n + 1} 0 R /V {n + 2} 0 R /P 6 0 R /R [0 0 10 10]>>");
                pdf.Obj(n + 10, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [6 0 R /Fit]>>");
                pdf.Obj(n + 11, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A 73 0 R>>");
                pdf.Obj(73, "<</S /GoTo /D [5 0 R /Fit] /Next [71 0 R 74 0 R]>>");
                pdf.Obj(74, "<</S /URI /URI (http://c) /Next 75 0 R>>");
                pdf.Obj(75, "<</S /GoTo /D [6 0 R /Fit]>>");
                pdf.Obj(n + 20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /V (x) /Rect [0 0 10 10]>>");
                pdf.Obj(n + 21, $"<</FT /Tx /T (b) /V (y) /Kids [{n + 22} 0 R {n + 23} 0 R]>>");
                pdf.Obj(n + 22, $"<</Type /Annot /Subtype /Widget /Parent {n + 21} 0 R /Rect [0 0 10 10]>>");
                pdf.Obj(n + 23, $"<</Type /Annot /Subtype /Widget /Parent {n + 21} 0 R /Rect [0 0 10 10]>>");
            });
    }

    // A page with a pattern, a shared pattern dictionary, annotations of each geometry and boxes.
    private static PdfDocument Drawn()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 300]>>")
            .Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Pattern <</P1 6 0 R /P2 7 0 R>>>> /TrimBox [10 10 190 290] /BleedBox [0 0 300 300] /Annots [8 0 R]>>")
            .Obj(4, "<</Type /Page /Parent 2 0 R /Contents [9 0 R 10 0 R] /Rotate 90 /UserUnit 2 /Resources <</Pattern <</P2 7 0 R>>>>>>")
            .Stream(5, "", "/Pattern cs /P1 scn 0 0 100 100 re f /P2 scn 0 0 10 10 re f")
            .Stream(6, "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Matrix [1 0 0 1 5 5]", "0 0 5 5 re f")
            .Obj(7, "<</PatternType 2 /Shading <</ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1>>>>>>")
            .Obj(8, "<</Type /Annot /Subtype /Ink /Rect [20 30 60 90] /InkList [[20 30 40 60 60 90] [1 2]] /RD [1 2 3 4] /QuadPoints [20 30 60 30 20 90 60 90] /L [0 0 10 10] /Vertices [1 2 3] /CL [1 2 3 4 5 6]>>")
            .Stream(9, "", "0 0 m 10 10 l S")
            .Stream(10, "", "5 5 m 20 20 l S");
        return PdfDocument.Open(pdf.Finish());
    }

    private static IEnumerable<string> Case(string name)
    {
        PdfDocument document;
        switch (name)
        {
            case "rotate":
                document = PageTestFiles.Open(3, rootExtra: "/Rotate 90");
                PageOperations.Rotate(document, [0, 2], 90);
                PageOperations.Rotate(document, [1], -90);
                PageOperations.Rotate(document, [2], 360);
                break;
            case "boxes":
                document = PageTestFiles.Open(2, pageExtra: i => i == 0 ? "/TrimBox [0 0 100 100] /ArtBox [5 5 6 6]" : "");
                PageOperations.SetBox(document, [1], PageBox.Crop, new PdfRect(10, 20, 110, 220));
                PageOperations.SetBox(document, [0, 1], PageBox.Art, new PdfRect(20, 30, 100, 400));
                PageOperations.SetBox(document, [0], PageBox.Trim, null);
                PageOperations.SetBox(document, [1], PageBox.Media, new PdfRect(0, 0, 400, 500));
                PageOperations.RemoveTransitions(document, [0, 1]);
                break;
            case "resize-scale":
                document = Drawn();
                PageOperations.Resize(document, [0, 1], 400, 300, ResizeMode.ScaleContent);
                break;
            case "resize-box":
                document = Drawn();
                PageOperations.Resize(document, [1, 0], 100, 150, ResizeMode.ChangeBox);
                break;
            case "delete":
                document = Linked();
                PageOperations.Delete(document, [1, 3]);
                break;
            case "delete-first":
                document = Linked();
                PageOperations.Delete(document, [0]);
                break;
            case "delete-tagged":
                document = PageTestFiles.Open(3, "/StructTreeRoot 40 0 R /MarkInfo <</Marked true>>", i => $"/StructParents {i}", add: pdf => pdf.Obj(40, "<</Type /StructTreeRoot>>"));
                PageOperations.Delete(document, [1]);
                break;
            case "reorder":
                document = PageTestFiles.Open(70);
                PageOperations.Reorder(document, [.. Enumerable.Range(0, 70).Reverse()]);
                break;
            case "move":
                document = PageTestFiles.Open(5, "/PageLabels <</Nums [0 <</S /r>> 2 <</S /D>>]>>");
                PageOperations.Move(document, [1, 2], 5);
                PageOperations.Move(document, [4, 3], 0);
                break;
            case "duplicate":
                document = Annotated();
                PageOperations.Duplicate(document, [0, 2]);
                break;
            case "insert-blank":
                document = PageTestFiles.Open(4, "/PageLabels <</Nums [0 <</S /r>> 2 <</S /D>>]>>");
                PageOperations.InsertBlank(document, 2, 595.5, 842, 2);
                PageOperations.InsertBlank(document, 0, 100, 100);
                break;
            case "import":
                document = PageTestFiles.Open(2);
                PageOperations.ImportPages(document, PdfDocument.Open(PageImportTests.Source()), [2, 0, 0], 1);
                break;
            case "import-annotated":
                document = PageTestFiles.Open(1);
                PageOperations.ImportPages(document, Annotated(), [0, 1], 1);
                PageOperations.ImportPages(document, Annotated(), [0], 0);
                break;
            case "import-self":
                document = Annotated();
                PageOperations.ImportPages(document, document, [1, 0], 2);
                break;
            case "extract":
                return Dump(PageAssembly.Extract(Annotated(), [1, 0]));
            case "extract-linked":
                return Dump(PageAssembly.Extract(Linked(), [3, 0]));
            case "merge":
                return Dump(PageAssembly.Merge([new MergeSource(PageTestFiles.Open(2)), new MergeSource(Annotated(), [0, 1]), new MergeSource(PdfDocument.Open(PageImportTests.Source()), [2])]));
            case "split-every":
                return Parts(PageAssembly.SplitEvery(PageTestFiles.Open(5), 2));
            case "split-at":
                return Parts(PageAssembly.SplitAt(Linked(), [3, 1]));
            case "split-size":
                return Parts(PageAssembly.SplitBySize(PageTestFiles.Open(6), 1400));
            default:
                return [$"unknown case {name}"];
        }
        return Dump(document);
    }
}
