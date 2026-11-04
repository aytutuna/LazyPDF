using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

internal static class FormFixtures
{
    private const string Helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>";

    /// <summary>
    /// A one-page form (600 by 800): text "name" and multiline "bio", check box "agree", radio group "choice"
    /// (buttons a and b), combo "city", multi-select list "langs", comb "code", password "secret", signature "sig".
    /// </summary>
    public static byte[] Standard(string acroEntries = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 10 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [20 0 R 21 0 R 22 0 R 24 0 R 25 0 R 26 0 R 27 0 R 28 0 R 29 0 R 33 0 R]>>");
        pdf.Obj(10, $"<</Fields [20 0 R 21 0 R 22 0 R 23 0 R 26 0 R 27 0 R 28 0 R 29 0 R 33 0 R] /DA (/Helv 0 Tf 0 g) /DR <</Font <</Helv 11 0 R>>>> {acroEntries}>>");
        pdf.Obj(11, Helvetica);
        pdf.Obj(20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [50 700 250 720] /F 4 /P 3 0 R /MK <</BC [0] /BG [1 1 0.8]>> /DA (/Helv 12 Tf 0 0 1 rg)>>");
        pdf.Obj(21, "<</Type /Annot /Subtype /Widget /FT /Tx /Ff 4096 /T (bio) /Rect [50 600 250 680] /F 4 /P 3 0 R /MK <</BC [0]>>>>");
        pdf.Obj(22, "<</Type /Annot /Subtype /Widget /FT /Btn /T (agree) /Rect [50 560 64 574] /F 4 /P 3 0 R /AS /Off /MK <</BC [0] /CA (4)>> /AP <</N <</Yes 30 0 R /Off 31 0 R>>>>>>");
        pdf.Obj(23, "<</FT /Btn /Ff 49152 /T (choice) /V /Off /Kids [24 0 R 25 0 R]>>");
        pdf.Obj(24, "<</Type /Annot /Subtype /Widget /Parent 23 0 R /Rect [50 520 64 534] /F 4 /P 3 0 R /AS /Off /MK <</BC [0] /CA (l)>> /AP <</N <</a 30 0 R /Off 31 0 R>>>>>>");
        pdf.Obj(25, "<</Type /Annot /Subtype /Widget /Parent 23 0 R /Rect [100 520 114 534] /F 4 /P 3 0 R /AS /Off /MK <</BC [0] /CA (l)>> /AP <</N <</b 30 0 R /Off 31 0 R>>>>>>");
        pdf.Obj(26, "<</Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (city) /Rect [50 480 200 498] /F 4 /P 3 0 R /Opt [(Ankara) [(IZ) (Izmir)] (Bursa)] /MK <</BC [0]>>>>");
        pdf.Obj(27, "<</Type /Annot /Subtype /Widget /FT /Ch /Ff 2097152 /T (langs) /Rect [50 380 200 460] /F 4 /P 3 0 R /Opt [(Turkish) (English) (German) (French) (Dutch) (Greek) (Latin)] /MK <</BC [0]>>>>");
        pdf.Obj(28, "<</Type /Annot /Subtype /Widget /FT /Tx /Ff 16777216 /MaxLen 6 /T (code) /Rect [50 340 170 360] /F 4 /P 3 0 R /MK <</BC [0]>>>>");
        pdf.Obj(29, "<</Type /Annot /Subtype /Widget /FT /Tx /Ff 8192 /T (secret) /Rect [50 300 200 320] /F 4 /P 3 0 R /MK <</BC [0]>>>>");
        pdf.Stream(30, "/Type /XObject /Subtype /Form /BBox [0 0 14 14]", "0 0 14 14 re f");
        pdf.Stream(31, "/Type /XObject /Subtype /Form /BBox [0 0 14 14]", "");
        pdf.Obj(33, "<</Type /Annot /Subtype /Widget /FT /Sig /T (sig) /Rect [300 300 450 340] /F 4 /P 3 0 R>>");
        return pdf.Finish();
    }

    public static PdfDocument Open(string acroEntries = "") => PdfDocument.Open(Standard(acroEntries));

    /// <summary>The words drawn by a widget's normal appearance, in order.</summary>
    public static string Drawn(PdfDocument document, FormWidget widget)
    {
        var ap = document.Dict(widget.Dictionary, "AP");
        var normal = document.Resolve(ap?["N"]);
        if (normal is PdfDictionary states) normal = document.Resolve(states[document.Name(widget.Dictionary, "AS") ?? "Off"]);
        var stream = normal as PdfStream ?? throw new Xunit.Sdk.XunitException("The widget has no normal appearance.");
        var recorder = new TextRecorder();
        new ContentInterpreter(document).Run(stream, recorder);
        return recorder.Text;
    }

    private sealed class TextRecorder : ContentVisitor
    {
        private readonly System.Text.StringBuilder _text = new();

        public string Text => _text.ToString();

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => _text.Append(glyph.Unicode);
    }
}
