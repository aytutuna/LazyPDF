using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

internal static class ContentTestPdf
{
    public const string Helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>";

    /// <summary>A one-page file: the content is object 4, objects 5 on come from <paramref name="objects"/>.</summary>
    public static PdfDocument Page(string content, string resources = "", params string[] objects) =>
        Page(Latin(content), resources, objects);

    public static PdfDocument Page(byte[] content, string resources = "", params string[] objects) =>
        Page(content, resources, pdf =>
        {
            for (int i = 0; i < objects.Length; i++) pdf.Obj(5 + i, objects[i]);
        });

    /// <summary>As above, <paramref name="more"/> adds the objects from number 5 on.</summary>
    public static PdfDocument Page(string content, string resources, Action<TestPdf> more) => Page(Latin(content), resources, more);

    public static PdfDocument Page(byte[] content, string resources, Action<TestPdf> more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<{resources}>>>>");
        pdf.Stream(4, "", content);
        more(pdf);
        return PdfDocument.Open(pdf.Finish());
    }

    public static byte[] Latin(string text) => Encoding.Latin1.GetBytes(text);

    public static IReadOnlyList<ContentOperation> Parse(string text) => ContentParser.Parse(Latin(text));

    public static Recorder Run(PdfDocument document)
    {
        var recorder = new Recorder();
        new ContentInterpreter(document).Run(document.Pages[0], recorder);
        return recorder;
    }
}

internal sealed class Recorder : ContentVisitor
{
    public List<GlyphInfo> Glyphs { get; } = [];
    public List<int> RenderModes { get; } = [];
    public List<(PathInfo Path, GraphicsState State)> Paths { get; } = [];
    public List<ImageInfo> Images { get; } = [];
    public List<ShadingInfo> Shadings { get; } = [];
    public List<string> Events { get; } = [];
    public List<(int Index, int FormDepth, int? Mcid)> Where { get; } = [];

    public string Text => string.Concat(Glyphs.Select(g => g.Unicode));

    public override void ShowGlyph(ContentContext context, in GlyphInfo glyph)
    {
        Glyphs.Add(glyph);
        RenderModes.Add(context.State.RenderMode);
        Where.Add((context.OperatorIndex, context.Forms.Count, context.Mcid));
    }

    public override void PaintPath(ContentContext context, PathInfo path)
    {
        Paths.Add((path, context.State.Clone()));
        Where.Add((context.OperatorIndex, context.Forms.Count, context.Mcid));
    }

    public override void PaintImage(ContentContext context, ImageInfo image) => Images.Add(image);

    public override void PaintShading(ContentContext context, ShadingInfo shading) => Shadings.Add(shading);

    public override void BeginMarked(ContentContext context, MarkedContent marked) =>
        Events.Add($"begin {marked.Tag}{(marked.Mcid is { } m ? " " + m : "")}");

    public override void EndMarked(ContentContext context, MarkedContent marked) => Events.Add($"end {marked.Tag}");

    public override void BeginForm(ContentContext context, FormInfo form) => Events.Add(form.IsPattern ? "pattern" : "form");

    public override void EndForm(ContentContext context, FormInfo form) => Events.Add("endform");
}
