using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ActionTests
{
    private static PdfAction? Read(string body, Action<TestPdf>? more = null)
    {
        var document = StructureFixtures.File("", pdf =>
        {
            pdf.Obj(20, body);
            more?.Invoke(pdf);
        });
        return PdfActions.Read(document, new PdfReference(20, 0));
    }

    [Fact]
    public void GoToWithExplicitDestination()
    {
        var action = Assert.IsType<GoToAction>(Read("<</S /GoTo /D [4 0 R /XYZ 5 6 null]>>"));
        Assert.Equal(new PdfDestination(1, DestinationFit.Xyz, 5, Top: 6), action.Destination);
    }

    [Fact]
    public void GoToWithoutDestinationIsNull()
    {
        Assert.Null(Read("<</S /GoTo>>"));
    }

    [Fact]
    public void GoToRemote()
    {
        var action = Assert.IsType<GoToRemoteAction>(Read("<</S /GoToR /F (other.pdf) /D [2 /Fit] /NewWindow true>>"));
        Assert.Equal("other.pdf", action.File);
        Assert.Equal(2, action.Destination!.PageIndex);
        Assert.True(action.NewWindow);
    }

    [Fact]
    public void GoToRemoteWithFileSpecAndNamedDestination()
    {
        var action = Assert.IsType<GoToRemoteAction>(Read("<</S /GoToR /F <</Type /Filespec /F (a.pdf) /UF (b.pdf)>> /D (chapter1)>>"));
        Assert.Equal("b.pdf", action.File);
        Assert.Equal("chapter1", action.Destination!.Name);
    }

    [Fact]
    public void UriIsUtf8WithLatin1Fallback()
    {
        Assert.Equal("https://example.com/a?b=1", Assert.IsType<UriAction>(Read("<</S /URI /URI (https://example.com/a?b=1)>>")).Uri);
        Assert.Equal("http://x/é", Assert.IsType<UriAction>(Read("<</S /URI /URI <687474703A2F2F782FC3A9>>>")).Uri);
        Assert.Equal("http://x/é", Assert.IsType<UriAction>(Read("<</S /URI /URI <687474703A2F2F782FE9>>>")).Uri);
    }

    [Fact]
    public void LaunchNamedAndJavaScript()
    {
        var launch = Assert.IsType<LaunchAction>(Read("<</S /Launch /F (tool.exe)>>"));
        Assert.Equal(("tool.exe", null), (launch.File, launch.NewWindow));
        Assert.Equal("NextPage", Assert.IsType<NamedAction>(Read("<</S /Named /N /NextPage>>")).Name);
        Assert.Equal("app.alert(1);", Assert.IsType<JavaScriptAction>(Read("<</S /JavaScript /JS (app.alert\\(1\\);)>>")).Script);
    }

    [Fact]
    public void JavaScriptMayBeAStream()
    {
        var action = Read("<</S /JavaScript /JS 21 0 R>>", pdf => pdf.Stream(21, "", "this.print();"));
        Assert.Equal("this.print();", Assert.IsType<JavaScriptAction>(action).Script);
    }

    [Fact]
    public void FormActionsListFieldNames()
    {
        var submit = Assert.IsType<SubmitFormAction>(Read("<</S /SubmitForm /F <</FS /URL /F (http://x/post)>> /Flags 4 /Fields [(name) 22 0 R]>>",
            pdf => pdf.Obj(22, "<</FT /Tx /T (email)>>")));
        Assert.Equal(("http://x/post", 4), (submit.Url, submit.Flags));
        Assert.Equal(["name", "email"], submit.Fields);
        var reset = Assert.IsType<ResetFormAction>(Read("<</S /ResetForm>>"));
        Assert.Empty(reset.Fields);
    }

    [Theory]
    [InlineData("Hide")]
    [InlineData("SetOCGState")]
    [InlineData("ImportData")]
    [InlineData("Rendition")]
    [InlineData("Whatever")]
    public void UnknownKindsAreOther(string kind)
    {
        Assert.Equal(kind, Assert.IsType<OtherAction>(Read($"<</S /{kind}>>")).Type);
    }

    [Fact]
    public void NextChainsAreReadInOrder()
    {
        var action = Read("<</S /Named /N /NextPage /Next [<</S /URI /URI (a)>> 21 0 R]>>", pdf => pdf.Obj(21, "<</S /JavaScript /JS (x) /Next <</S /Named /N /LastPage>>>>"));
        Assert.Equal(2, action!.Next.Count);
        Assert.IsType<UriAction>(action.Next[0]);
        var js = Assert.IsType<JavaScriptAction>(action.Next[1]);
        Assert.Equal("LastPage", Assert.IsType<NamedAction>(js.Next.Single()).Name);
    }

    [Fact]
    public void ChainThatLoopsStops()
    {
        var action = Read("<</S /Named /N /A /Next 21 0 R>>", pdf => pdf.Obj(21, "<</S /Named /N /B /Next 20 0 R>>"));
        Assert.Equal("B", Assert.IsType<NamedAction>(action!.Next.Single()).Name);
        Assert.Empty(action.Next[0].Next);
    }

    [Fact]
    public void LongChainIsCapped()
    {
        var action = Read("<</S /Named /N /A /Next 21 0 R>>", pdf =>
        {
            for (int i = 0; i < 500; i++) pdf.Obj(21 + i, $"<</S /Named /N /A{i} /Next {22 + i} 0 R>>");
        });
        int depth = 0;
        for (var at = action; at is not null && at.Next.Count > 0; at = at.Next[0]) depth++;
        Assert.InRange(depth, 1, 70);
    }

    [Fact]
    public void WideChainIsCapped()
    {
        var items = string.Concat(Enumerable.Repeat("<</S /Named /N /X>> ", 1000));
        var action = Read($"<</S /Named /N /A /Next [{items}]>>");
        Assert.InRange(action!.Next.Count, 1, 64);
    }

    [Fact]
    public void WritesAndReadsBack()
    {
        var document = StructureFixtures.Open();
        PdfAction[] actions =
        [
            new GoToAction(new PdfDestination(2, DestinationFit.FitH, Top: 7)),
            new GoToRemoteAction("o.pdf", new PdfDestination(3), true),
            new LaunchAction("x.exe", null),
            new UriAction("https://example.com/é"),
            new NamedAction("PrevPage"),
            new JavaScriptAction("var s = \"é\";"),
            new SubmitFormAction("http://x", 4, ["a", "b"]),
            new ResetFormAction(0, []),
            new NamedAction("A") { Next = [new UriAction("u"), new NamedAction("B") { Next = [new NamedAction("C")] }] },
        ];
        foreach (var action in actions)
        {
            var written = PdfActions.ToObject(document, action);
            Assert.Equal(action.GetType(), PdfActions.Read(document, written)!.GetType());
            AssertSame(action, PdfActions.Read(document, written)!);
        }
    }

    private static void AssertSame(PdfAction expected, PdfAction actual)
    {
        Assert.Equal(expected with { Next = [] }, actual with { Next = [] }, new ActionComparer());
        Assert.Equal(expected.Next.Count, actual.Next.Count);
        for (int i = 0; i < expected.Next.Count; i++) AssertSame(expected.Next[i], actual.Next[i]);
    }

    // Field lists are compared by content.
    private sealed class ActionComparer : IEqualityComparer<PdfAction>
    {
        public bool Equals(PdfAction? x, PdfAction? y) => (x, y) switch
        {
            (SubmitFormAction a, SubmitFormAction b) => a.Url == b.Url && a.Flags == b.Flags && a.Fields.SequenceEqual(b.Fields),
            (ResetFormAction a, ResetFormAction b) => a.Flags == b.Flags && a.Fields.SequenceEqual(b.Fields),
            _ => object.Equals(x, y),
        };

        public int GetHashCode(PdfAction obj) => 0;
    }

    [Fact]
    public void OtherActionsCannotBeWritten()
    {
        Assert.Throws<ArgumentException>(() => PdfActions.ToObject(StructureFixtures.Open(), new OtherAction("Hide")));
    }

    [Fact]
    public void GoToWithAPageThatIsGoneCannotBeWritten()
    {
        Assert.Throws<ArgumentException>(() => PdfActions.ToObject(StructureFixtures.Open(), new GoToAction(new PdfDestination(40))));
    }

    [Fact]
    public void DocumentActionsAreListed()
    {
        var document = StructureFixtures.File(
            "/OpenAction 20 0 R /AA <</WC <</S /JavaScript /JS (close\\(\\))>> /DS <</S /Named /N /Print>>>> /Names <</JavaScript <</Names [(init) 21 0 R (zeta) 22 0 R]>>>>",
            pdf =>
            {
                pdf.Obj(20, "<</S /GoTo /D [3 0 R /Fit]>>");
                pdf.Obj(21, "<</S /JavaScript /JS (var a = 1;)>>");
                pdf.Obj(22, "<</S /JavaScript /JS (var b = 2;)>>");
            });
        var all = PdfActions.ReadDocument(document);
        Assert.Equal(0, Assert.IsType<GoToAction>(all.OpenAction).Destination.PageIndex);
        Assert.Equal(["WC", "DS"], all.Triggers.Select(t => t.Event));
        Assert.Equal([("init", "var a = 1;"), ("zeta", "var b = 2;")], all.Scripts.Select(s => (s.Name, s.Script)));
        Assert.True(PdfActions.HasJavaScript(document));
    }

    [Fact]
    public void OpenActionMayBeADestinationArray()
    {
        var document = StructureFixtures.File("/OpenAction [5 0 R /Fit]");
        Assert.Equal(2, Assert.IsType<GoToAction>(PdfActions.ReadDocument(document).OpenAction).Destination.PageIndex);
        Assert.False(PdfActions.HasJavaScript(document));
    }

    [Fact]
    public void JavaScriptIsFoundInPagesAndWidgets()
    {
        var plain = StructureFixtures.File("");
        Assert.False(PdfActions.HasJavaScript(plain));

        var onPage = StructureFixtures.File("", pageEntries: "/AA <</O <</S /JavaScript /JS (x)>>>>");
        Assert.True(PdfActions.HasJavaScript(onPage));

        var widget = StructureFixtures.File("", pdf => pdf.Obj(20, "<</Type /Annot /Subtype /Widget /Rect [0 0 1 1] /AA <</K <</S /JavaScript /JS (y)>>>>>>"),
            pageEntries: "/Annots [20 0 R]");
        Assert.True(PdfActions.HasJavaScript(widget));

        var inChain = StructureFixtures.File("", pdf => pdf.Obj(20, "<</Type /Annot /Subtype /Link /Rect [0 0 1 1] /A <</S /Named /N /Print /Next <</S /JavaScript /JS (z)>>>>>>"),
            pageEntries: "/Annots [20 0 R]");
        Assert.True(PdfActions.HasJavaScript(inChain));

        var links = StructureFixtures.File("", pdf => pdf.Obj(20, "<</Type /Annot /Subtype /Link /Rect [0 0 1 1] /A <</S /URI /URI (http://x)>>>>"),
            pageEntries: "/Annots [20 0 R]");
        Assert.False(PdfActions.HasJavaScript(links));
    }

    [Fact]
    public void TriggersOfAnyDictionary()
    {
        var document = StructureFixtures.File("", pageEntries: "/AA <</O <</S /Named /N /NextPage>> /C <</S /Named /N /PrevPage>>>>");
        var triggers = PdfActions.Triggers(document, document.Pages[0].Dictionary);
        Assert.Equal(["O", "C"], triggers.Select(t => t.Event));
        Assert.Empty(PdfActions.Triggers(document, null));
    }

    [Fact]
    public void ScriptBehindALongChainIsFound()
    {
        var document = StructureFixtures.File("/OpenAction 20 0 R", pdf =>
        {
            for (int i = 0; i < 12; i++) pdf.Obj(20 + i, $"<</S /Named /N /NextPage /Next {21 + i} 0 R>>");
            pdf.Obj(32, "<</S /JavaScript /JS (x)>>");
        });
        Assert.True(PdfActions.HasJavaScript(document));
    }

    [Theory]
    [InlineData("<</S /URI /URI 5 /Next <</S /JavaScript /JS (x)>>>>")]
    [InlineData("<</S /GoTo /Next <</S /JavaScript /JS (x)>>>>")]
    public void ScriptBehindAnActionThatFailsToBuildIsFound(string body)
    {
        var document = StructureFixtures.File("/OpenAction 20 0 R", pdf => pdf.Obj(20, body));
        Assert.True(PdfActions.HasJavaScript(document));
        Assert.Single(Assert.IsType<OtherAction>(PdfActions.ReadDocument(document).OpenAction).Next);
    }

    [Fact]
    public void AnActionReadFromAFileThatCannotBeWrittenIsRefusedOnTheWay()
    {
        var document = StructureFixtures.File("", pdf => pdf.Obj(20, "<</S /Hide /T (x) /Next <</S /GoTo /D [99 0 R /Fit]>>>>"));
        var action = PdfActions.Read(document, new PdfReference(20, 0))!;
        Assert.Throws<ArgumentException>(() => PdfActions.ToObject(document, action));
    }
}
