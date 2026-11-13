using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

internal static class PdfUaKit
{
    public static readonly DateTimeOffset Date = new(2026, 3, 4, 10, 30, 0, TimeSpan.Zero);

    private const string Ids = "/ID [<0102030405060708090A0B0C0D0E0F10> <0102030405060708090A0B0C0D0E0F10>]";

    public const string Figure = "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC";

    /// <summary>The packet of /Info's title and creator tool, with pdfuaid:part when <paramref name="ua"/> is set.</summary>
    public static string Packet(bool ua = true, bool title = true)
    {
        var meta = new DocumentMetadata(title ? "Title" : null, null, null, null, "Test", "Test", Date, Date, new Dictionary<string, string>());
        string xmp = Encoding.UTF8.GetString(PdfAPacket.Xmp(PdfALevel.A2b, meta, Date, declare: false));
        return ua
            ? xmp.Replace("xmlns:dc=", "xmlns:pdfuaid=\"http://www.aiim.org/pdfua/ns/id/\"\n    xmlns:dc=").Replace("   <dc:format>", "   <pdfuaid:part>1</pdfuaid:part>\n   <dc:format>")
            : xmp;
    }

    /// <summary>The structure objects 9 to 12: Document, one Figure drawing the blue square, one parent tree array.</summary>
    public static SortedDictionary<int, string> Objects() => new()
    {
        [9] = "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R>>",
        [10] = "<</Type /StructElem /S /Document /P 9 0 R /K 11 0 R>>",
        [11] = "<</Type /StructElem /S /Figure /P 10 0 R /Pg 3 0 R /K 0 /Alt (A blue square)>>",
        [12] = "<</Nums [0 [11 0 R]]>>",
    };

    /// <summary>
    /// A one-page file that follows PDF/UA-1. The arguments replace the parts a test breaks; <paramref name="edit"/> changes the
    /// structure objects and <paramref name="extra"/> adds objects from 13 on. An empty <paramref name="xmp"/> leaves the packet out.
    /// </summary>
    public static byte[] Build(string markInfo = "/MarkInfo <</Marked true>>", string lang = "/Lang (en-US)", string viewer = "/ViewerPreferences <</DisplayDocTitle true>>",
        string? xmp = null, bool tree = true, string catalog = "", string page = "/Tabs /S", string content = Figure, string resources = "",
        Action<SortedDictionary<int, string>>? edit = null, Action<TestPdf>? extra = null, string info = "<</Title (Title) /Creator (Test) /Producer (Test)>>")
    {
        var objects = Objects();
        edit?.Invoke(objects);
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {(xmp == "" ? "" : "/Metadata 5 0 R")} {(tree ? "/StructTreeRoot 9 0 R" : "")} {markInfo} {lang} {viewer} {catalog}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<{resources}>> /StructParents 0 {page}>>");
        pdf.Stream(4, "", content);
        if (xmp != "") pdf.Stream(5, "/Type /Metadata /Subtype /XML", Encoding.UTF8.GetBytes(xmp ?? Packet()));
        pdf.Obj(8, info);
        if (tree)
        {
            foreach (var (number, body) in objects) pdf.Obj(number, body);
        }
        extra?.Invoke(pdf);
        return pdf.Finish($"/Root 1 0 R /Info 8 0 R {Ids}");
    }

    public static PdfUaReport Check(byte[] file)
    {
        using var document = PdfDocument.Open(file);
        return PdfUaValidator.Validate(document);
    }

    public static IReadOnlyList<string> Conditions(byte[] file) => [.. Check(file).Issues.Select(i => i.Condition).Distinct()];

    public static string Describe(PdfUaReport report) => string.Join("\n", report.Issues.Select(i => $"{i.Condition} {i.Clause} {i.Where}: {i.Message}"));
}
