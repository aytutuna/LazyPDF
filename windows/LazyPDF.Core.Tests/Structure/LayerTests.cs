using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class LayerTests
{
    private static PdfDocument Sample(string config = "/OFF [31 0 R] /Locked [32 0 R] /Order [30 0 R (Group) [31 0 R 32 0 R]]") =>
        StructureFixtures.File($"/OCProperties <</OCGs [30 0 R 31 0 R 32 0 R 33 0 R] /D <<{config}>>>>", pdf =>
        {
            pdf.Obj(30, "<</Type /OCG /Name (Background) /Intent /View>>");
            pdf.Obj(31, "<</Type /OCG /Name <FEFF0416> /Intent [/Design /View]>>");
            pdf.Obj(32, "<</Type /OCG>>");
            pdf.Obj(33, "<</Type /OCG /Name (Extra)>>");
        });

    [Fact]
    public void ReadsLayersWithStateLockAndIntent()
    {
        var set = PdfLayers.Read(Sample());
        Assert.Equal(["Background", "Ж", StructureText.UnnamedLayer, "Extra"], set.Layers.Select(l => l.Name));
        Assert.Equal([true, false, true, true], set.Layers.Select(l => l.IsOn));
        Assert.Equal([false, false, true, false], set.Layers.Select(l => l.Locked));
        Assert.Equal(["View", "Design", null, null], set.Layers.Select(l => l.Intent));
        Assert.Equal(30, set.Layers[0].Reference.Number);
    }

    [Fact]
    public void OrderTreeHasLabelsChildrenAndStragglers()
    {
        var order = PdfLayers.Read(Sample()).Order;
        Assert.Equal(3, order.Count);
        Assert.Equal("Background", order[0].Layer!.Name);
        Assert.Equal("Group", order[1].Label);
        Assert.Null(order[1].Layer);
        Assert.Equal(["Ж", StructureText.UnnamedLayer], order[1].Children.Select(c => c.Layer!.Name));
        Assert.Equal("Extra", order[2].Layer!.Name);
    }

    [Fact]
    public void LayerFollowedByAnArrayOwnsIt()
    {
        var order = PdfLayers.Read(Sample("/Order [30 0 R [31 0 R] [32 0 R]]")).Order;
        Assert.Equal("Background", order[0].Layer!.Name);
        Assert.Equal("Ж", Assert.Single(order[0].Children).Layer!.Name);
        Assert.Null(order[1].Layer);
        Assert.Equal(StructureText.UnnamedLayer, Assert.Single(order[1].Children).Layer!.Name);
    }

    [Fact]
    public void NoOrderListsEveryLayer()
    {
        var set = PdfLayers.Read(Sample(""));
        Assert.Equal(4, set.Order.Count);
        Assert.All(set.Layers, l => Assert.True(l.IsOn));
    }

    [Fact]
    public void BaseStateOffUsesOn()
    {
        var set = PdfLayers.Read(Sample("/BaseState /OFF /ON [30 0 R 33 0 R]"));
        Assert.Equal([true, false, false, true], set.Layers.Select(l => l.IsOn));
        var unchanged = PdfLayers.Read(Sample("/BaseState /Unchanged /OFF [33 0 R]"));
        Assert.Equal([true, true, true, false], unchanged.Layers.Select(l => l.IsOn));
    }

    [Fact]
    public void NoLayersNoSet()
    {
        var set = PdfLayers.Read(StructureFixtures.Open());
        Assert.Empty(set.Layers);
        Assert.Empty(set.Order);
    }

    [Fact]
    public void HidingAndShowingSurviveASave()
    {
        var document = Sample();
        Assert.True(PdfLayers.SetVisible(document, new PdfReference(30, 0), false));
        Assert.True(PdfLayers.SetVisible(document, new PdfReference(31, 0), true));
        var reopened = StructureFixtures.Reopen(document);
        var set = PdfLayers.Read(reopened);
        Assert.Equal([false, true, true, true], set.Layers.Select(l => l.IsOn));
        var config = reopened.Dict(reopened.Dict(reopened.Catalog, "OCProperties"), "D")!;
        Assert.Null(config["BaseState"]);
        Assert.Null(config["ON"]);
        Assert.Equal("[30 0 R]", config["OFF"]!.ToString());
        Assert.NotNull(config["Order"]);
        Assert.NotNull(config["Locked"]);
    }

    [Fact]
    public void BaseStateOffIsRewrittenAsOnWithAnOffList()
    {
        var document = Sample("/BaseState /OFF /ON [30 0 R]");
        PdfLayers.SetVisible(document, new PdfReference(33, 0), true);
        var set = PdfLayers.Read(StructureFixtures.Reopen(document));
        Assert.Equal([true, false, false, true], set.Layers.Select(l => l.IsOn));
    }

    [Fact]
    public void NoOffLayersRemovesTheList()
    {
        var document = Sample();
        PdfLayers.SetVisible(document, new PdfReference(31, 0), true);
        Assert.Null(document.Dict(document.Dict(document.Catalog, "OCProperties"), "D")!["OFF"]);
    }

    [Fact]
    public void ConfigIsMadeWhenMissing()
    {
        var document = StructureFixtures.File("/OCProperties <</OCGs [30 0 R]>>", pdf => pdf.Obj(30, "<</Type /OCG /Name (Only)>>"));
        PdfLayers.SetVisible(document, new PdfReference(30, 0), false);
        Assert.False(PdfLayers.Read(StructureFixtures.Reopen(document)).Layers.Single().IsOn);
    }

    [Fact]
    public void RadioButtonGroupTurnsTheOthersOff()
    {
        var document = Sample("/OFF [30 0 R] /RBGroups [[30 0 R 31 0 R 33 0 R]]");
        PdfLayers.SetVisible(document, new PdfReference(31, 0), true);
        Assert.Equal([false, true, true, false], PdfLayers.Read(document).Layers.Select(l => l.IsOn));
        PdfLayers.SetVisible(document, new PdfReference(30, 0), true);
        Assert.Equal([true, false, true, false], PdfLayers.Read(document).Layers.Select(l => l.IsOn));
        PdfLayers.SetVisible(document, new PdfReference(33, 0), false);
        Assert.Equal([true, false, true, false], PdfLayers.Read(document).Layers.Select(l => l.IsOn));
    }

    [Fact]
    public void RadioGroupsListTheKnownLayers()
    {
        var document = Sample("/RBGroups [[30 0 R 31 0 R] [32 0 R 33 0 R 99 0 R] [30 0 R] [31 0 R 98 0 R]]");
        var groups = PdfLayers.Read(document).RadioGroups;
        Assert.Equal(2, groups.Count);
        Assert.Equal([30, 31], groups[0].Select(r => r.Number));
        Assert.Equal([32, 33], groups[1].Select(r => r.Number));
        Assert.Empty(PdfLayers.Read(Sample()).RadioGroups);
    }

    [Fact]
    public void RepeatedAndSelfReferencingGroupsAreReadOnce()
    {
        var refs = string.Join(' ', Enumerable.Repeat("34 0 R", 5000));
        var document = StructureFixtures.File($"/OCProperties <</OCGs [30 0 R 31 0 R] /D <</RBGroups [{refs} 35 0 R]>>>>", pdf =>
        {
            pdf.Obj(30, "<</Type /OCG /Name (A)>>");
            pdf.Obj(31, "<</Type /OCG /Name (B)>>");
            pdf.Obj(34, "[30 0 R 31 0 R 34 0 R]");
            pdf.Obj(35, "[35 0 R 30 0 R 31 0 R]");
        });
        var groups = PdfLayers.Read(document).RadioGroups;
        Assert.Equal(2, groups.Count);
        Assert.Equal([30, 31], groups[0].Select(r => r.Number));
    }

    [Fact]
    public void TurningALayerOnReadsRepeatedGroupsOnce()
    {
        var refs = string.Join(' ', Enumerable.Repeat("34 0 R", 20000));
        var members = string.Join(' ', Enumerable.Repeat("30 0 R", 20000));
        var document = StructureFixtures.File($"/OCProperties <</OCGs [30 0 R 31 0 R] /D <</OFF [30 0 R] /RBGroups [{refs}]>>>>", pdf =>
        {
            pdf.Obj(30, "<</Type /OCG /Name (A)>>");
            pdf.Obj(31, "<</Type /OCG /Name (B)>>");
            pdf.Obj(34, $"[31 0 R {members}]");
        });
        var watch = System.Diagnostics.Stopwatch.StartNew();
        Assert.True(PdfLayers.SetVisible(document, new PdfReference(30, 0), true));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5));
        Assert.Equal([true, false], PdfLayers.Read(document).Layers.Select(l => l.IsOn));
    }

    [Fact]
    public void UnknownLayerIsRefused()
    {
        var document = Sample();
        Assert.False(PdfLayers.SetVisible(document, new PdfReference(99, 0), false));
        Assert.False(PdfLayers.SetVisible(StructureFixtures.Open(), new PdfReference(30, 0), false));
    }

    [Fact(Timeout = 20000)]
    public async Task AnOrderThatListsItselfIsReadOnce()
    {
        var document = StructureFixtures.File("/OCProperties <</OCGs [30 0 R] /D <</Order 31 0 R>>>>", pdf =>
        {
            pdf.Obj(30, "<</Type /OCG /Name (A)>>");
            pdf.Obj(31, "[31 0 R 31 0 R 31 0 R 31 0 R 30 0 R]");
        });
        var set = await Task.Run(() => PdfLayers.Read(document));
        Assert.Single(set.Layers);
        Assert.True(set.Order.Count < 10);
        Assert.Contains(set.Order, n => n.Layer is not null);
    }

    [Fact]
    public void JunkAndLoopsInOrderAreTolerated()
    {
        var document = StructureFixtures.File("/OCProperties <</OCGs [30 0 R 30 0 R 5 null 99 0 R] /D <</Order 31 0 R /ON 7>>>>", pdf =>
        {
            pdf.Obj(30, "<</Type /OCG /Name (A)>>");
            pdf.Obj(31, "[30 0 R 30 0 R 31 0 R (x) 3 [[[[[[[[[[[[[[[[[[[[30 0 R]]]]]]]]]]]]]]]]]]]]]");
        });
        var set = PdfLayers.Read(document);
        Assert.Single(set.Layers);
        Assert.NotEmpty(set.Order);
    }
}
