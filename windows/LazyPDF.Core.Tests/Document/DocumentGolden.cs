using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Document/DocumentGolden.swift. One line of input is "<op> <name> [<how>]": a file
// built by both sides (the names below), read, repaired, updated or rewritten, and what came of it, in text.
//   open <name>                      the reader's view of the file: repairs, pages, every object
//   incremental <name>               the file edited by SaveFixtures.Edit and saved as an update
//   rewrite <name> plain|packed      the file saved by SaveRewrite
// A file that holds nothing random or compressed is written out byte for byte (the update, or the whole rewrite),
// with the second string of /ID, which is random, set to zeros; any other is described as it reads back. Deflate
// output differs between implementations, so nothing that hangs on the size of compressed data is printed for the
// files that have some.
internal static class DocumentGolden
{
    private static readonly string[] Exact = ["table", "stream", "hybrid"];

    public static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            string[] words = line.Split(' ');
            output.Append("> ").Append(line).Append('\n');
            foreach (string result in Op(words[0], words[1], words.ElementAtOrDefault(2)))
            {
                output.Append("< ").Append(result).Append('\n');
            }
        }
        return output.ToString();
    }

    private static IEnumerable<string> Op(string op, string name, string? how)
    {
        try
        {
            switch (op)
            {
                case "open":
                    return Describe(Make(name), layout: !Packed(name));
                case "incremental":
                {
                    byte[] original = Make(name);
                    var document = PdfDocument.Open(original);
                    SaveFixtures.Edit(document);
                    byte[] saved = document.SaveIncremental();
                    return Exact.Contains(name) ? Lines(saved.AsSpan(original.Length).ToArray()) : Describe(saved, layout: false);
                }
                case "rewrite":
                {
                    var document = PdfDocument.Open(Make(name));
                    byte[] saved = document.SaveRewrite(new PdfSaveOptions(UseObjectStreams: how == "packed", Security: document.Security));
                    return Exact.Contains(name) && how == "plain" ? Lines(saved) : Describe(saved, layout: false);
                }
                default:
                    return [$"unknown op {op}"];
            }
        }
        catch (PdfReadException e)
        {
            return [$"error {e.Problem} {e.Message}"];
        }
    }

    private static bool Packed(string name) => name.StartsWith("aes", StringComparison.Ordinal) || name.StartsWith("object", StringComparison.Ordinal);

    /// <summary>The bytes as escaped lines, one to each line of the file, with the second /ID string zeroed.</summary>
    private static IEnumerable<string> Lines(byte[] file)
    {
        byte[] masked = MaskId(file);
        var lines = new List<string>();
        int start = 0;
        for (int i = 0; i < masked.Length; i++)
        {
            if (masked[i] != 10) continue;
            lines.Add(Golden.Escape(masked[start..i]));
            start = i + 1;
        }
        if (start < masked.Length) lines.Add(Golden.Escape(masked[start..]));
        return lines;
    }

    private static byte[] MaskId(byte[] file)
    {
        byte[] copy = (byte[])file.Clone();
        byte[] marker = "/ID [<"u8.ToArray();
        for (int i = 0; i + marker.Length < copy.Length; i++)
        {
            if (!copy.AsSpan(i, marker.Length).SequenceEqual(marker)) continue;
            int p = i + marker.Length;
            while (p < copy.Length && copy[p] != (byte)'>') p++;
            if (p + 2 >= copy.Length || copy[p + 1] != (byte)' ' || copy[p + 2] != (byte)'<') continue;
            for (p += 3; p < copy.Length && copy[p] != (byte)'>'; p++) copy[p] = (byte)'0';
        }
        return copy;
    }

    private static List<string> Describe(byte[] file, bool layout)
    {
        var lines = new List<string>();
        PdfDocument document;
        try
        {
            document = PdfDocument.Open(file);
        }
        catch (PdfReadException e)
        {
            return [$"error {e.Problem} {e.Message}"];
        }
        string id = document.Id.Count > 0 ? Convert.ToHexString(document.Id[0]) : "-";
        lines.Add(layout ? $"version {document.Version} encrypted {Bool(document.IsEncrypted)} id {id}" : $"version {document.Version} encrypted {Bool(document.IsEncrypted)}");
        lines.Add($"facts signed {Bool(document.IsSigned)} certified {Bool(document.IsCertified)} xfa {Bool(document.HasXfa)} tagged {Bool(document.IsTagged)} linearized {Bool(document.IsLinearized)} pdfa {document.PdfAPart}{document.PdfAConformance}");
        if (layout)
        {
            lines.Add($"layout rebuilt {Bool(document.XrefRebuilt)} stream {Bool(document.XrefIsStream)} start {document.StartXref} next {document.NextObjectNumber} length {document.Length}");
        }
        else
        {
            lines.Add($"layout rebuilt {Bool(document.XrefRebuilt)} stream {Bool(document.XrefIsStream)} next {document.NextObjectNumber}");
        }
        lines.Add($"repairs {document.Repairs.Count}");
        foreach (string repair in document.Repairs) lines.Add($"repair {repair}");

        lines.Add($"pages {document.Pages.Count}");
        foreach (var page in document.Pages)
        {
            lines.Add($"page {page.Index} ref {page.Reference.Number} {page.Reference.Generation} media {Box(page.MediaBox)} crop {Box(page.CropBox)} rotate {page.Rotate} unit {new PdfNumber(page.UserUnit)} contents {Golden.Escape(page.Contents())}");
        }

        foreach (int number in document.ObjectNumbers)
        {
            string entry = layout ? $" {document.Entries[number].Kind} {document.Entries[number].Offset}" : "";
            var value = document.Get(number);
            // The salts and keys of a new handler are random.
            if (number == document.EncryptNumber)
            {
                lines.Add($"obj {number} gen {document.GenerationOf(number)}{entry} encryption dictionary");
                continue;
            }
            if (value is PdfStream stream)
            {
                bool xref = document.Name(stream.Dictionary, "Type") == "XRef";
                var copy = new PdfDictionary();
                foreach (var (key, item) in stream.Dictionary.Entries)
                {
                    // The second string of /ID is random, and /Prev is where a compressed section starts.
                    if (key != "Length" && !(xref && key is "ID" or "Prev")) copy.Add(key, item);
                }
                if (xref)
                {
                    lines.Add($"obj {number} gen {document.GenerationOf(number)}{entry} {copy}");
                    continue;
                }
                string data;
                try
                {
                    data = Golden.Escape(document.Data(stream));
                }
                catch (PdfReadException e)
                {
                    data = $"error {e.Problem}";
                }
                lines.Add($"obj {number} gen {document.GenerationOf(number)}{entry} {copy} data {data}");
            }
            else
            {
                lines.Add($"obj {number} gen {document.GenerationOf(number)}{entry} {value}");
            }
        }
        return lines;
    }

    private static string Bool(bool value) => value ? "yes" : "no";

    private static string Box(PdfRect rect) => $"[{new PdfNumber(rect.Left)} {new PdfNumber(rect.Bottom)} {new PdfNumber(rect.Right)} {new PdfNumber(rect.Top)}]";

    /// <summary>The file a name stands for. Swift builds the same ones with its twin of TestPdf.</summary>
    public static byte[] Make(string name)
    {
        switch (name)
        {
            case "table" or "stream" or "hybrid" or "objects" or "aes128" or "aes256" or "aes256objects":
                return SaveFixtures.Make(name);
            case "simple2":
                return TestPdf.Simple(2);
            case "junk-before":
                return [.. TestPdf.Latin("junk before\r\n"), .. TestPdf.Simple(2)];
            case "header-late":
                return [.. new byte[2000], .. TestPdf.Simple()];
            case "not-pdf":
                return TestPdf.Latin("hello");
            case "no-startxref":
                return TestPdf.Replace(TestPdf.Simple(), "startxref", "startxxxxx");
            case "startxref-past-end":
                return new TestPdf().Obj(1, "<</Type /Catalog /Pages 2 0 R>>").Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
                    .Obj(3, "<</Type /Page /Parent 2 0 R>>").Finish(startxref: "99999999");
            case "shifted":
                return TestPdf.WithPages(2).Finish(shift: 7);
            case "wrong-length":
                return TestPdf.WithPages(1).Stream(9, "", "twelve bytes", length: 3).Stream(10, "", "ten bytes!", length: 500)
                    .Stream(11, "", "no length", length: -1).Finish();
            case "no-endstream":
                return TestPdf.WithPages(1).Stream(9, "", "cut short", length: 400, endstream: false).Finish();
            case "no-trailer":
                return TestPdf.WithPages(2).FinishWithoutXref();
            case "no-root":
                return TestPdf.WithPages(2).Finish(trailer: "");
            case "truncated":
            {
                byte[] file = TestPdf.Simple(3);
                return file[..(file.Length - 120)];
            }
            case "no-catalog":
                return new TestPdf().Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>").Obj(3, "<</Type /Page /Parent 2 0 R>>")
                    .Obj(4, "<</Type /Page /Parent 2 0 R>>").FinishWithoutXref();
            case "no-tree":
                return new TestPdf().Obj(3, "<</Type /Page /MediaBox [0 0 10 10]>>").Obj(4, "<</Type /Page /MediaBox [0 0 20 20]>>").FinishWithoutXref();
            case "later-definition":
                return TestPdf.WithPages(1).Obj(3, "<</Type /Page /Parent 2 0 R /Rotate 180 /Contents 4 0 R>>").FinishWithoutXref();
            case "pdf-in-stream":
                return TestPdf.WithPages(1).Stream(8, "", "%PDF-1.4\n9 0 obj\n<</Type /Page /Rotate 90>>\nendobj\ntrailer\n<</Root 9 0 R>>\n").FinishWithoutXref();
            case "prev-broken":
            {
                byte[] first = TestPdf.WithPages(1).Finish();
                string objectText = "3 0 obj\n<</Type /Page /Parent 2 0 R /Rotate 90 /Contents 4 0 R>>\nendobj\n";
                string text = objectText + "xref\n3 1\n" + $"{first.Length:D10} 00000 n \n" + "trailer\n<</Size 5 /Root 1 0 R /Prev 5000000>>\nstartxref\n"
                              + (first.Length + objectText.Length) + "\n%%EOF\n";
                return [.. first, .. TestPdf.Latin(text)];
            }
            case "tree-ancestors":
                return new TestPdf()
                    .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
                    .Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 2 /MediaBox [0 0 100 200] /Rotate 90 /Resources <</Font <<>>>>>>")
                    .Obj(3, "<</Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R] /Count 2 /CropBox [10 10 60 60]>>")
                    .Obj(4, "<</Type /Page /Parent 3 0 R>>")
                    .Obj(5, "<</Type /Page /Parent 3 0 R /Rotate 270 /MediaBox [0 0 50 50] /Resources <</XObject <<>>>>>>")
                    .Finish();
            case "tree-cycle":
                return new TestPdf()
                    .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
                    .Obj(2, "<</Type /Pages /Kids [3 0 R 2 0 R 4 0 R] /Count 2>>")
                    .Obj(3, "<</Type /Page /Parent 2 0 R>>")
                    .Obj(4, "<</Type /Pages /Parent 2 0 R /Kids [2 0 R 5 0 R]>>")
                    .Obj(5, "<</Type /Page /Parent 4 0 R>>")
                    .Finish();
            case "tree-junk":
                return new TestPdf()
                    .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
                    .Obj(2, "<</Type /Pages /Kids [3 0 R 42 (text) null 77 0 R 6 0 R <</Type /Page>> 5 0 R 3 0 R] /Count 2>>")
                    .Obj(3, "<</Type /Page>>")
                    .Obj(5, "<</Type /Font /BaseFont /Helvetica>>")
                    .Obj(6, "[1 2 3]")
                    .Finish();
            case "tree-boxes":
                return new TestPdf()
                    .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
                    .Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>")
                    .Obj(3, "<</Type /Page /MediaBox [300 400 0 0] /TrimBox [5 5 15 25] /Rotate 450 /UserUnit 2>>")
                    .Obj(4, "<</Type /Page /MediaBox [0 0 0 0] /CropBox [1 2] /Rotate -90 /UserUnit -3 /BleedBox (x)>>")
                    .Finish();
            case "object-stream":
            {
                var pdf = ObjectStreamTests.ObjectStreamFile(out long xref);
                return [.. pdf.FinishWithoutXref(), .. TestPdf.Latin($"startxref\n{xref}\n%%EOF\n")];
            }
            case "object-stream-lost":
            {
                var pdf = ObjectStreamTests.ObjectStreamFile(out _);
                return [.. pdf.FinishWithoutXref(), .. TestPdf.Latin("startxref\n12\n%%EOF\n")];
            }
            default:
                throw new ArgumentException(name);
        }
    }
}
