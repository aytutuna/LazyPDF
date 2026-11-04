using System.Text;
using LazyPDF.Core;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

internal sealed class EditArialSource : IFontSource
{
    public FontFile? Find(string family, FontStyles style)
    {
        string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf");
        Assert.True(File.Exists(path), "arial.ttf is not installed; these tests need it");
        return new FontFile(File.ReadAllBytes(path));
    }
}

/// <summary>A glyph as the interpreter places it, for comparing a page before and after an edit.</summary>
internal sealed record EditGlyphAt(string Text, double X, double Y, double Size);

/// <summary>A glyph with the state it is drawn in.</summary>
internal sealed record EditShown(string Text, double X, double Y, double Size, RgbColor Color, double Tc, double Tw);

internal static class EditKit
{
    public const string Helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>";
    public const string Times = "<</Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding>>";

    /// <summary>A one page file, 600 by 800, with Helvetica as /F1 and Times as /F2; extra objects start at 7.</summary>
    public static byte[] File(string content, string pageKeys = "", Action<TestPdf>? more = null, string resources = "/Font <</F1 5 0 R /F2 6 0 R>>")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<{resources}>> {pageKeys}>>");
        pdf.Stream(4, "", content);
        pdf.Obj(5, Helvetica);
        pdf.Obj(6, Times);
        more?.Invoke(pdf);
        return pdf.Finish();
    }

    public static PdfEditSession Session(string content, string pageKeys = "", Action<TestPdf>? more = null, string resources = "/Font <</F1 5 0 R /F2 6 0 R>>") =>
        PdfEditSession.Open(File(content, pageKeys, more, resources));

    /// <summary>The page text as the engine reads it, with the whole file reopened first.</summary>
    public static string Text(PdfEditSession session, int page = 0)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        return TextPage.Create(document, document.Pages[page]).Text;
    }

    public static string Pig(PdfEditSession session, int page = 1)
    {
        using var pig = PigDocument.Open(session.Current.ToArray());
        return pig.GetPage(page).Text;
    }

    public static List<EditGlyphAt> Glyphs(PdfEditSession session, int page = 0)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        var found = new List<EditGlyphAt>();
        new ContentInterpreter(document).Run(document.Pages[page], new Collect(found));
        return found;
    }

    public static List<EditShown> Shown(PdfEditSession session, int page = 0)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        var found = new List<EditShown>();
        new ContentInterpreter(document).Run(document.Pages[page], new Observe(found));
        return found;
    }

    /// <summary>The glyphs of a word, found in the order they are drawn.</summary>
    public static List<EditShown> Of(List<EditShown> shown, string word)
    {
        int at = string.Concat(shown.Select(s => s.Text)).IndexOf(word, StringComparison.Ordinal);
        Assert.True(at >= 0, word);
        return shown.GetRange(at, word.Length);
    }

    public static TextRange Find(PdfEditSession session, string word, int page = 0)
    {
        var text = TextPage.Create(session.Document, session.Document.Pages[page]);
        var match = TextSearch.Find(text, word, new TextSearchOptions(MatchCase: true)).First();
        return match.Range;
    }

    public static string Latin(PdfEditSession session, int page = 0) => Encoding.Latin1.GetString(session.Document.Pages[page].Contents());

    private sealed class Observe(List<EditShown> found) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
        {
            var s = context.State;
            found.Add(new EditShown(glyph.Unicode ?? "", Math.Round(glyph.Matrix.E, 2), Math.Round(glyph.Matrix.F, 2), Math.Round(glyph.Matrix.D, 2), s.FillColor.Rgb, s.CharSpacing, s.WordSpacing));
        }
    }

    private sealed class Collect(List<EditGlyphAt> found) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) =>
            found.Add(new EditGlyphAt(glyph.Unicode ?? "", Math.Round(glyph.Matrix.E, 3), Math.Round(glyph.Matrix.F, 3), Math.Round(glyph.Matrix.D, 3)));
    }
}
