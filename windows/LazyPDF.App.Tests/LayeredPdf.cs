using System.Text;
using LazyPDF.Core;

namespace LazyPDF.App.Tests;

/// <summary>A one page file whose black square is on a layer ("Black box", object 5), written by hand.</summary>
internal static class LayeredPdf
{
    public static readonly PdfReference BlackBox = new(5, 0);

    public static byte[] Make()
    {
        const string content = "/OC /L1 BDC 0 0 0 rg 20 20 160 160 re f EMC";
        string[] objects =
        [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /Order [5 0 R 6 0 R] /ON [5 0 R 6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << /Properties << /L1 5 0 R /L2 6 0 R >> >> >>",
            $"<< /Length {content.Length} >>\nstream\n{content}\nendstream",
            "<< /Type /OCG /Name (Black box) >>",
            "<< /Type /OCG /Name (Notes) >>",
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
        return Encoding.ASCII.GetBytes(file.ToString());
    }
}
