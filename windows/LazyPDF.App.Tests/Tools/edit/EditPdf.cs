using System.Text;

namespace LazyPDF.App.Tests.Tools.Edit;

/// <summary>A one page file written by hand: Helvetica as /F1, the content as given.</summary>
internal static class EditPdf
{
    public static byte[] Make(string content, string pageKeys = "")
    {
        string[] objects =
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792] >>",
            $"<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> {pageKeys} >>",
            $"<< /Length {content.Length} >>\nstream\n{content}\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ];
        var file = new StringBuilder("%PDF-1.7\n");
        var offsets = new List<int>();
        for (int i = 0; i < objects.Length; i++)
        {
            offsets.Add(file.Length);
            file.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n");
        }
        int xref = file.Length;
        file.Append($"xref\n0 {objects.Length + 1}\n0000000000 65535 f \n");
        foreach (int offset in offsets) file.Append($"{offset:D10} 00000 n \n");
        file.Append($"trailer\n<< /Size {objects.Length + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return Encoding.Latin1.GetBytes(file.ToString());
    }

    public const string Paragraph = "BT /F1 12 Tf 14 TL 50 700 Td (The first line of this text runs along) Tj T* (the second line and keeps going here) Tj T* (and the third line ends it) Tj ET";
}
