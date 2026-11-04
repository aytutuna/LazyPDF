using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// The interpreter enters 20 forms deep; the 20th is the last one it reads and what it calls is out of sight.
public class RedactDepthTests
{
    private static readonly PdfRect Near = new(90, 90, 200, 120);

    // Forms 6 to 25 call the next one; form 25 shows "near" and calls form 26, which holds the secret.
    private static PdfDocument Chain() =>
        RedactionKit.Page("/F6 Do", "/XObject <</F6 6 0 R>>", pdf =>
        {
            for (int i = 6; i < 25; i++)
            {
                pdf.Stream(i, $"/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</XObject <</F{i + 1} {i + 1} 0 R>>>>", $"/F{i + 1} Do");
            }
            pdf.Stream(25, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</F26 26 0 R>>>>", "BT /F1 12 Tf 100 100 Td (near) Tj ET /F26 Do");
            pdf.Stream(26, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 300 300 Td (ZQXDEEPSECRET) Tj ET");
        });

    [Fact]
    public void LastFormReadHasItsCallDroppedWithoutALeftoverCopy()
    {
        using var document = Chain();
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)]);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXDEEPSECRET"));
        Assert.False(RedactionKit.Holds(result.Bytes, "near"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void ContentItemNamingTheDroppedFormLeavesTheTree()
    {
        using var document = Chain();
        var root = new PdfDictionary { ["Type"] = new PdfName("StructTreeRoot") };
        var top = new PdfDictionary();
        var figure = new PdfDictionary();
        var rootRef = document.Add(root);
        var topRef = document.Add(top);
        var figureRef = document.Add(figure);
        root["K"] = new PdfArray([topRef]);
        top["Type"] = new PdfName("StructElem");
        top["S"] = new PdfName("Document");
        top["P"] = rootRef;
        top["K"] = new PdfArray([figureRef]);
        figure["Type"] = new PdfName("StructElem");
        figure["S"] = new PdfName("Figure");
        figure["P"] = topRef;
        figure["Pg"] = document.Pages[0].Reference;
        figure["K"] = new PdfDictionary { ["Type"] = new PdfName("MCR"), ["Pg"] = document.Pages[0].Reference, ["Stm"] = new PdfReference(25, 0), ["MCID"] = new PdfNumber(0) };
        figure["Alt"] = PdfText.ToObject("ZQXALT");
        document.Catalog["StructTreeRoot"] = rootRef;
        var result = new PdfRedactor(document).Apply([RedactionMark.FromRect(0, Near)]);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXALT"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXDEEPSECRET"));
    }
}
