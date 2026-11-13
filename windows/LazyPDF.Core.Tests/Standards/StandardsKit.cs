using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Finds Arial, Times New Roman, Courier New and Symbol in the Windows fonts folder; anything else gets Arial.</summary>
internal sealed class SystemFonts : IFontSource
{
    public FontFile? Find(string family, FontStyles style)
    {
        int index = (style.HasFlag(FontStyles.Bold) ? 1 : 0) + (style.HasFlag(FontStyles.Italic) ? 2 : 0);
        string[] names = family.ToLowerInvariant() switch
        {
            "times new roman" => ["times.ttf", "timesbd.ttf", "timesi.ttf", "timesbi.ttf"],
            "courier new" => ["cour.ttf", "courbd.ttf", "couri.ttf", "courbi.ttf"],
            "symbol" => ["symbol.ttf", "symbol.ttf", "symbol.ttf", "symbol.ttf"],
            _ => ["arial.ttf", "arialbd.ttf", "ariali.ttf", "arialbi.ttf"],
        };
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), names[index]);
        return File.Exists(path) ? new FontFile(File.ReadAllBytes(path)) : null;
    }

    public static void RequireArial() =>
        Assert.True(File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf")), "arial.ttf is not installed; these tests need it");
}

internal static class StandardsKit
{
    public static readonly DateTimeOffset Date = new(2026, 3, 4, 10, 30, 0, TimeSpan.Zero);

    private const string Binary = "%\u00E2\u00E3\u00CF\u00D3\n";
    private const string Ids = "/ID [<0102030405060708090A0B0C0D0E0F10> <0102030405060708090A0B0C0D0E0F10>]";

    /// <summary>
    /// A small file that follows PDF/A-2b: a blue square in DeviceRGB, the sRGB output intent, XMP identification and
    /// /Info in step (the shape Lazy Scan writes). <paramref name="catalog"/>, <paramref name="page"/> and <paramref name="content"/> add to it.
    /// </summary>
    public static byte[] Compliant(PdfALevel level = PdfALevel.A2b, string catalog = "", string page = "", string content = "0 0 1 rg 20 20 100 100 re f",
        string resources = "", Action<TestPdf>? extra = null, string? xmp = null, string info = "", string header = "", string intents = "/OutputIntents [6 0 R]")
    {
        var pdf = new TestPdf(header.Length > 0 ? header : (level == PdfALevel.A4 ? "%PDF-2.0\n" : "%PDF-1.7\n") + Binary);
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R /Metadata 5 0 R {intents} {catalog}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<{resources}>> {page}>>");
        pdf.Stream(4, "", content);
        pdf.Stream(5, "/Type /Metadata /Subtype /XML", xmp is null ? Encoding.UTF8.GetBytes(Packet(level)) : Encoding.UTF8.GetBytes(xmp));
        pdf.Obj(6, "<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1) /Info (sRGB IEC61966-2.1) /DestOutputProfile 7 0 R>>");
        pdf.Stream(7, "/N 3", PdfASrgb.SrgbProfile);
        string dates = "/CreationDate (D:20260304103000Z) /ModDate (D:20260304103000Z)";
        pdf.Obj(8, info.Length > 0 ? info : level == PdfALevel.A4 ? $"<<{dates}>>" : $"<</Title (Title) /Creator (Test) /Producer (Test) {dates}>>");
        extra?.Invoke(pdf);
        return pdf.Finish($"/Root 1 0 R /Info 8 0 R {Ids}");
    }

    /// <summary>
    /// <see cref="Compliant"/> with a structure tree: a Document holding one Figure that draws the blue square, with a
    /// description, the language and /MarkInfo. The arguments replace the parts a test breaks.
    /// </summary>
    public static byte[] Tagged(PdfALevel level, string marked = "/MarkInfo <</Marked true>>", string lang = "/Lang (en-US)", string roleMap = "",
        string figureType = "Figure", string alt = "/Alt (A blue square)", string content = "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC") =>
        Compliant(level, catalog: $"/StructTreeRoot 9 0 R {marked} {lang}", page: "/StructParents 0", content: content, extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R {roleMap}>>");
            pdf.Obj(10, "<</Type /StructElem /S /Document /P 9 0 R /K 11 0 R>>");
            pdf.Obj(11, $"<</Type /StructElem /S /{figureType} /P 10 0 R /Pg 3 0 R /K 0 {alt}>>");
            pdf.Obj(12, "<</Nums [0 [11 0 R]]>>");
        });

    /// <summary>The XMP packet that goes with the info dictionary of <see cref="Compliant"/>.</summary>
    public static string Packet(PdfALevel level)
    {
        var meta = level == PdfALevel.A4
            ? new DocumentMetadata(null, null, null, null, null, null, Date, Date, new Dictionary<string, string>())
            : new DocumentMetadata("Title", null, null, null, "Test", "Test", Date, Date, new Dictionary<string, string>());
        return Encoding.UTF8.GetString(PdfAPacket.Xmp(level, meta, Date));
    }

    public static PdfAReport Check(byte[] file, PdfALevel level = PdfALevel.A2b)
    {
        using var document = PdfDocument.Open(file);
        return PdfAValidator.Validate(document, level);
    }

    public static IEnumerable<string> Clauses(byte[] file, PdfALevel level = PdfALevel.A2b) => Check(file, level).Issues.Select(i => i.Clause).Distinct();

    /// <summary>Rewrites the file after <paramref name="edit"/> changed its objects, so that only the edit is wrong in it.</summary>
    public static byte[] Edited(byte[] file, Action<PdfDocument> edit)
    {
        using var document = PdfDocument.Open(file);
        edit(document);
        return document.SaveRewrite();
    }

    public static string Latin(byte[] file) => Encoding.Latin1.GetString(file);

    public static byte[] Bytes(string text) => Encoding.Latin1.GetBytes(text);

    public static void AssertClean(byte[] file, PdfALevel level = PdfALevel.A2b)
    {
        var report = Check(file, level);
        Assert.True(report.IsValid, string.Join("\n", report.Issues.Select(i => $"{i.Clause} {i.Where}: {i.Message}")));
    }
}
