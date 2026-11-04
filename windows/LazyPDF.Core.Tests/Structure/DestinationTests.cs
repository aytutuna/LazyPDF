using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class DestinationTests
{
    private static PdfObject Array(PdfDocument document, int page, string rest) =>
        new PdfArray([document.Pages[page].Reference, .. ParseItems(rest)]);

    private static IEnumerable<PdfObject> ParseItems(string rest) =>
        rest.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(t =>
            t == "null" ? PdfNull.Instance : t.StartsWith('/') ? new PdfName(t[1..]) : (PdfObject)new PdfNumber(t));

    [Theory]
    [InlineData("/XYZ 10 250 2", DestinationFit.Xyz)]
    [InlineData("/XYZ null null null", DestinationFit.Xyz)]
    [InlineData("/Fit", DestinationFit.Fit)]
    [InlineData("/FitH 120", DestinationFit.FitH)]
    [InlineData("/FitV 30", DestinationFit.FitV)]
    [InlineData("/FitR 10 20 100 200", DestinationFit.FitR)]
    [InlineData("/FitB", DestinationFit.FitB)]
    [InlineData("/FitBH 99", DestinationFit.FitBH)]
    [InlineData("/FitBV 5", DestinationFit.FitBV)]
    public void EveryFitModeRoundTrips(string rest, DestinationFit fit)
    {
        var document = StructureFixtures.Open();
        var parsed = PdfDestinations.Parse(document, Array(document, 1, rest));
        Assert.NotNull(parsed);
        Assert.Equal(1, parsed.PageIndex);
        Assert.Equal(fit, parsed.Fit);
        var written = PdfDestinations.ToObject(document, parsed);
        Assert.Equal(parsed, PdfDestinations.Parse(document, written));
    }

    [Fact]
    public void ValuesAreKeptPerFit()
    {
        var document = StructureFixtures.Open();
        var xyz = PdfDestinations.Parse(document, Array(document, 0, "/XYZ 10 250 2"))!;
        Assert.Equal((10, 250, 2), (xyz.Left!.Value, xyz.Top!.Value, xyz.Zoom!.Value));
        var rect = PdfDestinations.Parse(document, Array(document, 0, "/FitR 1 2 3 4"))!;
        Assert.Equal((1, 2, 3, 4), (rect.Left!.Value, rect.Bottom!.Value, rect.Right!.Value, rect.Top!.Value));
        var nulls = PdfDestinations.Parse(document, Array(document, 0, "/XYZ null null null"))!;
        Assert.Null(nulls.Left);
        Assert.Null(nulls.Zoom);
    }

    [Fact]
    public void ZeroZoomIsWrittenAsNull()
    {
        var document = StructureFixtures.Open();
        var array = (PdfArray)PdfDestinations.ToObject(document, new PdfDestination(0, DestinationFit.Xyz, 1, Top: 2, Zoom: 0))!;
        Assert.IsType<PdfNull>(array.Items[4]);
    }

    [Fact]
    public void BrokenArraysAreNull()
    {
        var document = StructureFixtures.Open();
        Assert.Null(PdfDestinations.Parse(document, new PdfArray([])));
        Assert.Null(PdfDestinations.Parse(document, new PdfArray([document.Pages[0].Reference])));
        Assert.Null(PdfDestinations.Parse(document, Array(document, 0, "/Bogus 1")));
        Assert.Null(PdfDestinations.Parse(document, new PdfNumber(3)));
        Assert.Null(PdfDestinations.Parse(document, null));
    }

    [Fact]
    public void PageThatIsGoneHasIndexMinusOne()
    {
        var document = StructureFixtures.Open();
        var parsed = PdfDestinations.Parse(document, new PdfArray([new PdfReference(99, 0), new PdfName("Fit")]));
        Assert.Equal(-1, parsed!.PageIndex);
        Assert.Null(PdfDestinations.ToObject(document, parsed));
        Assert.Null(PdfDestinations.Locate(document, parsed));
    }

    [Fact]
    public void DictionaryFormUsesD()
    {
        var document = StructureFixtures.Open();
        var dictionary = new PdfDictionary { ["D"] = Array(document, 2, "/Fit") };
        Assert.Equal(2, PdfDestinations.Parse(document, dictionary)!.PageIndex);
    }

    [Fact]
    public void RemoteDestinationUsesPageNumbers()
    {
        var document = StructureFixtures.Open();
        var parsed = PdfDestinations.Parse(document, new PdfArray([new PdfNumber(7), new PdfName("FitH"), new PdfNumber(50)]), remote: true)!;
        Assert.Equal(7, parsed.PageIndex);
        var written = (PdfArray)PdfDestinations.ToObject(document, parsed, remote: true)!;
        Assert.Equal("[7 /FitH 50]", written.ToString());
        Assert.Equal("chap", PdfDestinations.Parse(document, new PdfString("chap"u8.ToArray(), false), remote: true)!.Name);
    }

    [Fact]
    public void LocateAppliesRotationAndCropBox()
    {
        var document = StructureFixtures.Open();
        var page = document.Pages[0].Dictionary;
        page["Rotate"] = new PdfNumber(90);
        page["CropBox"] = new PdfArray([new PdfNumber(10), new PdfNumber(20), new PdfNumber(110), new PdfNumber(220)]);
        var point = PdfDestinations.Locate(document, new PdfDestination(0, DestinationFit.Xyz, 30, Top: 50, Zoom: 1.5))!.Value;
        var expected = new PageGeometry(document.Pages[0]).ToDisplay(30, 50);
        Assert.Equal(expected.X, point.X, 6);
        Assert.Equal(expected.Y, point.Y, 6);
        Assert.Equal(1.5, point.Zoom);
    }

    [Fact]
    public void LocateDefaultsToTopLeftAndClamps()
    {
        var document = StructureFixtures.Open();
        var fit = PdfDestinations.Locate(document, new PdfDestination(1))!.Value;
        Assert.Equal((0, 0), (fit.X, fit.Y));
        var far = PdfDestinations.Locate(document, new PdfDestination(1, DestinationFit.Xyz, -32768, Top: 900000))!.Value;
        Assert.Equal((0, 0), (far.X, far.Y));
        // The fixture pages are 200 by 300 points.
        var fitH = PdfDestinations.Locate(document, new PdfDestination(1, DestinationFit.FitH, Top: 100))!.Value;
        Assert.Equal((0, 200), (fitH.X, fitH.Y));
    }

    [Fact]
    public void NamedDestinationsInTreeAndOldDictionary()
    {
        var document = StructureFixtures.Open();
        document.Catalog["Dests"] = new PdfDictionary { ["old"] = Array(document, 0, "/Fit"), ["shared"] = Array(document, 0, "/Fit") };
        PdfDestinations.SetNamed(document, "new", new PdfDestination(2, DestinationFit.FitH, Top: 40));
        PdfDestinations.SetNamed(document, "shared", new PdfDestination(1));

        var named = PdfDestinations.Named(document);
        Assert.Equal(["old", "shared", "new"], named.Select(e => e.Key));
        var all = named.ToDictionary(e => e.Key, e => e.Value);
        Assert.Equal(0, all["old"].PageIndex);
        Assert.Equal(1, all["shared"].PageIndex);
        Assert.Equal(2, all["new"].PageIndex);
        Assert.Equal("new", all["new"].Name);

        // A name already in /Dests is updated there, not copied to the tree.
        var tree = document.Dict(document.Dict(document.Catalog, "Names"), "Dests");
        Assert.Equal(["new"], PdfNameTree.Read(document, tree).Select(e => e.Key));
    }

    [Fact]
    public void NamedDestinationsSurviveSaving()
    {
        var document = StructureFixtures.Open();
        for (int i = 0; i < 100; i++) PdfDestinations.SetNamed(document, $"d{i:D3}", new PdfDestination(i % 3));
        var reopened = StructureFixtures.Reopen(document);
        Assert.Equal(100, PdfDestinations.Named(reopened).Count);
        Assert.Equal(2, PdfDestinations.Find(reopened, "d002")!.PageIndex);
        Assert.Null(PdfDestinations.Find(reopened, "missing"));
    }

    [Fact]
    public void RemoveNamed()
    {
        var document = StructureFixtures.Open();
        document.Catalog["Dests"] = new PdfDictionary { ["old"] = Array(document, 0, "/Fit") };
        PdfDestinations.SetNamed(document, "new", new PdfDestination(1));
        Assert.True(PdfDestinations.RemoveNamed(document, "old"));
        Assert.True(PdfDestinations.RemoveNamed(document, "new"));
        Assert.False(PdfDestinations.RemoveNamed(document, "new"));
        Assert.Empty(PdfDestinations.Named(document));
    }

    [Fact]
    public void ANameResolvesThroughParse()
    {
        var document = StructureFixtures.Open();
        PdfDestinations.SetNamed(document, "intro", new PdfDestination(2));
        var byString = PdfDestinations.Parse(document, new PdfString("intro"u8.ToArray(), false))!;
        Assert.Equal((2, "intro"), (byString.PageIndex, byString.Name));
        var unknown = PdfDestinations.Parse(document, new PdfName("nowhere"))!;
        Assert.Equal((-1, "nowhere"), (unknown.PageIndex, unknown.Name));
    }

    [Fact]
    public void NameIsWrittenAsNameOnlyWhereTheFileHasJustAnOldDictionary()
    {
        var document = StructureFixtures.Open();
        document.Catalog["Dests"] = new PdfDictionary { ["old"] = Array(document, 0, "/Fit") };
        Assert.IsType<PdfName>(PdfDestinations.ToObject(document, new PdfDestination(-1, Name: "old")));
        PdfDestinations.SetNamed(document, "new", new PdfDestination(1));
        Assert.IsType<PdfString>(PdfDestinations.ToObject(document, new PdfDestination(-1, Name: "old")));
    }

    [Fact]
    public void DestinationWithoutPageCannotBeNamed()
    {
        var document = StructureFixtures.Open();
        Assert.Throws<ArgumentException>(() => PdfDestinations.SetNamed(document, "x", new PdfDestination(9)));
    }
}
