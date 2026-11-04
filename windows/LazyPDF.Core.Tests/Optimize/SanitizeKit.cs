using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

internal static class SanitizeKit
{
    public static readonly string[] Markers =
    [
        "MARKERJS1", "MARKERJS2", "MARKERJS3", "MARKERJS4", "MARKERATTACH", "MARKERPATH", "MARKERXMP", "MARKERTITLE", "MARKERAUTHOR", "MARKERPIECE",
        "MARKERBASE", "MARKERSPIDER", "MARKERNOTE", "MARKERHL", "MARKERURL", "MARKERLAUNCH", "MARKERFORM", "MARKEROLDREV", "MARKERTHUMB",
    ];

    /// <summary>
    /// A file with something of every kind in it, each marked, a first version with an old title, and a
    /// second that replaced it. Page text is "Visible text".
    /// </summary>
    public static byte[] Dirty()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /OpenAction 20 0 R /AA <</WC 21 0 R>> /Metadata 24 0 R /AcroForm 25 0 R /AF [23 0 R] " +
            "/Names <</JavaScript <</Names [(js1) 22 0 R]>> /EmbeddedFiles <</Names [(att.txt) 23 0 R]>> /IDS <</Names []>>>> " +
            "/PieceInfo <</App <</Data (MARKERPIECE)>>>> /URI <</Base (http://MARKERBASE.example/)>> /SpiderInfo <</X (MARKERSPIDER)>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> /XObject <</Im0 26 0 R>>>> /AA <</O 21 0 R>> /Thumb 37 0 R " +
            "/Annots [27 0 R 28 0 R 29 0 R 30 0 R 31 0 R 34 0 R]>>");
        pdf.Stream(4, "", "BT /F1 12 Tf 10 150 Td (Visible text) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Obj(20, "<</S /JavaScript /JS (app.alert\\('MARKERJS1'\\))>>");
        pdf.Obj(21, "<</S /JavaScript /JS 32 0 R>>");
        pdf.Obj(22, "<</S /JavaScript /JS (MARKERJS3)>>");
        pdf.Obj(23, "<</Type /Filespec /F (C:\\\\Users\\\\bob\\\\MARKERPATH.txt) /UF (C:\\\\Users\\\\bob\\\\MARKERPATH.txt) /EF <</F 33 0 R>>>>");
        pdf.Stream(24, "/Type /Metadata /Subtype /XML", "<x:xmpmeta>MARKERXMP</x:xmpmeta>");
        pdf.Obj(25, "<</Fields [34 0 R] /DA (/Helv 0 Tf 0 g) /DR <</Font <</Helv 5 0 R>>>>>>");
        pdf.Stream(26, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Alt (MARKERALT)", "abcd");
        pdf.Stream(37, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", "MARKERTHUMB");
        pdf.Obj(27, "<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (MARKERNOTE)>>");
        pdf.Obj(28, "<</Type /Annot /Subtype /Highlight /Rect [0 0 10 10] /QuadPoints [0 10 10 10 0 0 10 0] /Contents (MARKERHL)>>");
        pdf.Obj(29, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /URI /URI (http://MARKERURL.example/)>>>>");
        pdf.Obj(30, "<</Type /Annot /Subtype /Link /Rect [20 0 30 10] /A <</S /Launch /F (MARKERLAUNCH.exe)>>>>");
        pdf.Obj(31, "<</Type /Annot /Subtype /FileAttachment /Rect [40 0 50 10] /FS 23 0 R>>");
        pdf.Stream(32, "", "app.alert('MARKERJS2')");
        pdf.Stream(33, "/Type /EmbeddedFile", "MARKERATTACH");
        pdf.Obj(34, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (MARKERFORM) /Rect [10 100 150 120] /P 3 0 R /AA <</K 35 0 R>>>>");
        pdf.Obj(35, "<</S /JavaScript /JS (MARKERJS4)>>");
        pdf.Obj(36, "<</Title (MARKEROLDREV) /Author (MARKERAUTHOR)>>");
        byte[] first = pdf.Finish("/Root 1 0 R /Info 36 0 R");
        using var document = PdfDocument.Open(first);
        document.Info!["Title"] = new PdfString(System.Text.Encoding.Latin1.GetBytes("MARKERTITLE"), false);
        return document.SaveIncremental();
    }

    public static int Count(IReadOnlyList<SanitizeFinding> findings, SanitizeItem item) => findings.FirstOrDefault(f => f.Item == item)?.Count ?? 0;
}
