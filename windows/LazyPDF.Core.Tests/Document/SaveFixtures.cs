using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

/// <summary>
/// The same small two-page file (catalog 1, page tree 2, pages 3 and 4, contents 5 and 6, info 7)
/// laid out the ways a file can be: classic table, cross-reference stream, objects in object
/// streams, a hybrid, and encrypted.
/// </summary>
internal static class SaveFixtures
{
    public static readonly string[] Kinds = ["table", "stream", "objects", "hybrid", "aes128", "aes256", "aes256objects"];

    public static readonly byte[] FileId = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();

    private static readonly string[] Bodies =
    [
        "<</Type /Catalog /Pages 2 0 R>>",
        "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 300] /Resources <</Font <</F1 <</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>>>>>>>",
        "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>",
        "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>",
    ];

    public const string PageOne = "BT /F1 12 Tf 20 100 Td (Page one) Tj ET";
    public const string PageTwo = "BT /F1 12 Tf 20 100 Td (Page two) Tj ET";
    public const string Info = "<</Title (Original title) /Author (Someone)>>";

    public static byte[] Make(string kind) => kind switch
    {
        "table" => Table(),
        "stream" => Layout(hybrid: false),
        "hybrid" => Layout(hybrid: true),
        "objects" => Rewrite(Table(), new PdfSaveOptions(UseObjectStreams: true)),
        "aes128" => Rewrite(Table(), new PdfSaveOptions(Security: Secure(PdfCryptStrength.Aes128), DocumentId: FileId)),
        "aes256" => Rewrite(Table(), new PdfSaveOptions(Security: Secure(PdfCryptStrength.Aes256))),
        "aes256objects" => Rewrite(Table(), new PdfSaveOptions(true, Secure(PdfCryptStrength.Aes256))),
        _ => throw new ArgumentException(kind),
    };

    public static PdfSecurity Secure(PdfCryptStrength strength) =>
        PdfSecurity.Create("", "owner", PdfPermissions.All, strength, FileId, new Random(5));

    public static byte[] Rewrite(byte[] file, PdfSaveOptions options) => PdfDocument.Open(file).SaveRewrite(options);

    public static byte[] Table()
    {
        var pdf = new TestPdf();
        for (int i = 0; i < Bodies.Length; i++) pdf.Obj(i + 1, Bodies[i]);
        pdf.Stream(5, "", PageOne);
        pdf.Stream(6, "", PageTwo);
        pdf.Obj(7, Info);
        string id = Convert.ToHexString(FileId);
        return pdf.Finish($"/Root 1 0 R /Info 7 0 R /ID [<{id}> <{id}>]");
    }

    /// <summary>
    /// Cross-reference stream 8; with <paramref name="hybrid"/> a classic table instead, page 3 in
    /// object stream 8 and the stream 9 that lists it, which the table's /XRefStm points at.
    /// </summary>
    private static byte[] Layout(bool hybrid)
    {
        var file = new MemoryStream();
        var offsets = new SortedDictionary<int, long>();
        void Write(string text) => file.Write(TestPdf.Latin(text));
        void Obj(int number, string body)
        {
            offsets[number] = file.Length;
            Write($"{number} 0 obj\n{body}\nendobj\n");
        }
        void Stream(int number, string entries, string data) => Obj(number, $"<<{entries} /Length {data.Length}>>\nstream\n{data}\nendstream");
        string id = Convert.ToHexString(FileId);

        Write("%PDF-1.5\n");
        for (int i = 0; i < Bodies.Length; i++)
        {
            if (!(hybrid && i == 2)) Obj(i + 1, Bodies[i]);
        }
        Stream(5, "", PageOne);
        Stream(6, "", PageTwo);
        Obj(7, Info);
        if (!hybrid)
        {
            long start = file.Length;
            var rows = new List<byte>();
            void Row(int type, long second, int third)
            {
                rows.Add((byte)type);
                for (int b = 3; b >= 0; b--) rows.Add((byte)(second >> (b * 8)));
                rows.Add((byte)third);
            }
            Row(0, 0, 255);
            foreach (long offset in offsets.Values) Row(1, offset, 0);
            Row(1, start, 0);
            string data = Encoding.Latin1.GetString([.. rows]);
            Write($"8 0 obj\n<</Type /XRef /Size 9 /W [1 4 1] /Root 1 0 R /Info 7 0 R /ID [<{id}> <{id}>] /Length {data.Length}>>\nstream\n{data}\nendstream\nendobj\n");
            Write($"startxref\n{start}\n%%EOF\n");
            return file.ToArray();
        }

        string page = Bodies[2];
        string header = "3 0 ";
        Stream(8, $"/Type /ObjStm /N 1 /First {header.Length}", header + page);
        long xrefStream = file.Length;
        var row = new List<byte> { 2, 0, 0, 0, 8, 0 };
        Stream(9, "/Type /XRef /Size 10 /W [1 4 1] /Index [3 1]", Encoding.Latin1.GetString([.. row]));
        long table = file.Length;
        var sb = new StringBuilder("xref\n0 10\n0000000000 65535 f \n");
        for (int n = 1; n < 10; n++)
        {
            sb.Append(offsets.TryGetValue(n, out long at) ? $"{at:D10} 00000 n \n" : "0000000000 00000 f \n");
        }
        sb.Append($"trailer\n<</Size 10 /Root 1 0 R /Info 7 0 R /ID [<{id}> <{id}>] /XRefStm {xrefStream}>>\nstartxref\n{table}\n%%EOF\n");
        Write(sb.ToString());
        return file.ToArray();
    }

    public static string Title(PdfDocument document) => Encoding.Latin1.GetString(((PdfString)document.Info!["Title"]!).Bytes);

    /// <summary>A new title, new text on page two, and a new object the catalog points at.</summary>
    public static void Edit(PdfDocument document, string title = "New title")
    {
        document.Info!["Title"] = new PdfString(Encoding.Latin1.GetBytes(title), isHex: false);
        var contents = document.Resolve<PdfStream>(document.Pages[1].Dictionary["Contents"])!;
        contents.Data = TestPdf.Latin("BT /F1 12 Tf 20 100 Td (Changed) Tj ET");
        var note = new PdfDictionary();
        note.Add("Note", new PdfString(Encoding.Latin1.GetBytes("Added note"), isHex: false));
        document.Catalog["Extra"] = document.Add(note);
    }
}
