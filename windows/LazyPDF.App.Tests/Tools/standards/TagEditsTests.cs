using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Accessibility;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The edits of the tag tree editor on a document: one undo step each, what the placement rule refuses, and the read-only cases.
public sealed class TagEditsTests
{
    internal static string Page(int page) =>
        string.Join("\n\n", Enumerable.Range(0, 6).Select(i => $"Paragraph {i} of page {page} has its own words and numbers {page * 100 + i}."));

    // Tagged by the tagger: a Document with a paragraph or heading per block and real content behind each.
    internal static byte[] Auto()
    {
        var document = PdfDocument.Open(PdfFromText.Create(Page(1) + "\f" + Page(2), new FakeFonts()).Bytes);
        AutoTagger.Tag(document);
        return document.SaveIncremental();
    }

    // A tree made by hand over a page with no marked content: Document, then what the test adds.
    internal static byte[] Built(Action<StructureTree, StructElement> build)
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var tree = StructureTree.Create(document);
        var root = new StructElement("Document");
        tree.Add(null, root);
        build(tree, root);
        tree.Write(document);
        return document.SaveRewrite(new PdfSaveOptions());
    }

    // A tagged file that forbids changes.
    internal static byte[] Restricted()
    {
        var document = PdfDocument.Open(Auto());
        var security = PdfSecurity.Create("", "owner", PdfPermissions.All & ~PdfPermissions.Modify, PdfCryptStrength.Aes256, document.FirstId ?? []);
        return document.SaveRewrite(new PdfSaveOptions(Security: security));
    }

    internal static DocumentTab Open(byte[] bytes) => new(PdfEditSession.Open(bytes, (string?)null), new FakeRenderer(), null, "a.pdf", null);

    internal static StructElement El(StructureTree tree, StructElement? parent, string type, string? title = null)
    {
        var element = new StructElement(type) { Title = title };
        tree.Add(parent, element);
        return element;
    }

    // Everything the first page shows, so no marked sequence is cut by the selection.
    private static TextRange WholePage(DocumentTab tab) => new(0, TextPage.Create(tab.Document, tab.Document.Pages[0]).Chars.Count);

    private static StructElement Titled(StructureTree tree, string title) => tree.Elements.First(e => e.Title == title);

    private static IReadOnlyList<string?> Titles(StructElement parent) => parent.Children.Select(c => c.Title).ToList();

    private static TagOutcome Do(DocumentTab tab, string title, TagCommand command)
    {
        var tree = StructureTree.Read(tab.Document)!;
        return TagEdits.Apply(tab, TagPath.Of(tree, Titled(tree, title)), TagEdits.Label(command), (t, k) => TagEdits.Run(t, k!, command));
    }

    private static byte[] Three() => Built((tree, root) =>
    {
        var sect = El(tree, root, "Sect", "sect");
        El(tree, sect, "P", "one");
        El(tree, sect, "P", "two");
        El(tree, sect, "P", "three");
    });

    [Fact]
    public void AMoveIsOneUndoStepWithItsLabelAndUndoPutsTheOrderBack()
    {
        using var tab = Open(Three());

        var outcome = Do(tab, "one", TagCommand.MoveDown);

        Assert.Equal(TagResult.Done, outcome.Result);
        Assert.Equal("Move tag down", tab.Session.UndoLabel);
        Assert.Equal(["two", "one", "three"], Titles(Titled(StructureTree.Read(tab.Document)!, "sect")));
        Assert.True(tab.Undo());
        Assert.Equal(["one", "two", "three"], Titles(Titled(StructureTree.Read(tab.Document)!, "sect")));
    }

    [Fact]
    public void MovingUpAndOutdentingAndIndentingChangeTheNesting()
    {
        using var tab = Open(Three());

        Assert.Equal(TagResult.Done, Do(tab, "three", TagCommand.MoveUp).Result);
        Assert.Equal(["one", "three", "two"], Titles(Titled(StructureTree.Read(tab.Document)!, "sect")));

        Assert.Equal(TagResult.Done, Do(tab, "two", TagCommand.Outdent).Result);
        var tree = StructureTree.Read(tab.Document)!;
        Assert.Equal(["sect", "two"], Titles(tree.Roots[0]));

        Assert.Equal(TagResult.Done, Do(tab, "two", TagCommand.Indent).Result);
        Assert.Equal(["one", "three", "two"], Titles(Titled(StructureTree.Read(tab.Document)!, "sect")));
    }

    [Fact]
    public void AMoveThatBreaksTheNestingIsRefusedBeforeAnythingIsWritten()
    {
        using var tab = Open(Three());
        var tree = StructureTree.Read(tab.Document)!;
        var two = Titled(tree, "two");

        string? reason = TagEdits.Refusal(tree, two, TagCommand.Indent);
        var outcome = Do(tab, "two", TagCommand.Indent);

        Assert.Equal(AccessibilityText.PlacementReason(TagRules.TextKids), reason);
        Assert.Equal(TagResult.Refused, outcome.Result);
        Assert.Equal(reason, outcome.Reason);
        Assert.Null(tab.Session.UndoLabel);
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public void CommandsThatMeanNothingWhereTheNodeStandsAreOff()
    {
        using var tab = Open(Three());
        var tree = StructureTree.Read(tab.Document)!;

        Assert.False(TagEdits.Applies(tree, Titled(tree, "one"), TagCommand.MoveUp));
        Assert.False(TagEdits.Applies(tree, Titled(tree, "three"), TagCommand.MoveDown));
        Assert.False(TagEdits.Applies(tree, Titled(tree, "one"), TagCommand.Indent));
        Assert.False(TagEdits.Applies(tree, tree.Roots[0], TagCommand.Outdent));
        Assert.False(TagEdits.Applies(tree, Titled(tree, "one"), TagCommand.MakeHeaderRow));
        Assert.False(TagEdits.Applies(tree, Titled(tree, "one"), TagCommand.MarkAsArtifact));
        Assert.True(TagEdits.Applies(tree, Titled(tree, "two"), TagCommand.Indent));
    }

    [Fact]
    public void DeleteKeepsWhatTheTagHeldAndNeedsItsKidsToFitTheParent()
    {
        using var tab = Open(Built((tree, root) =>
        {
            var sect = El(tree, root, "Sect", "sect");
            El(tree, sect, "P", "one");
            El(tree, sect, "P", "two");
            var table = El(tree, root, "Table", "table");
            var row = El(tree, table, "TR", "row");
            El(tree, row, "TD", "cell");
        }));

        Assert.Equal(TagResult.Done, Do(tab, "sect", TagCommand.Delete).Result);
        var tree = StructureTree.Read(tab.Document)!;
        Assert.Equal(["one", "two", "table"], Titles(tree.Roots[0]));
        Assert.Equal("Delete tag", tab.Session.UndoLabel);

        var refused = Do(tab, "row", TagCommand.Delete);
        Assert.Equal(TagResult.Refused, refused.Result);
        Assert.Equal(AccessibilityText.PlacementReason(TagRules.NeedsRow), refused.Reason);
    }

    [Fact]
    public void MakeHeaderRowTurnsTheCellsIntoColumnHeaders()
    {
        using var tab = Open(Built((tree, root) =>
        {
            var table = El(tree, root, "Table");
            var row = El(tree, table, "TR", "row");
            El(tree, row, "TD", "a");
            El(tree, row, "TD", "b");
        }));

        Assert.Equal(TagResult.Done, Do(tab, "row", TagCommand.MakeHeaderRow).Result);

        var tree = StructureTree.Read(tab.Document)!;
        var cells = Titled(tree, "row").Children.ToList();
        Assert.All(cells, c => Assert.Equal("TH", c.Type));
        Assert.All(cells, c => Assert.Equal(TableScope.Column, tree.GetTableAttributes(c).Scope));
        Assert.Equal("Make header row", tab.Session.UndoLabel);
    }

    [Fact]
    public void TheFieldsChangeTypeTextAndTableAttributes()
    {
        using var tab = Open(Built((tree, root) =>
        {
            var table = El(tree, root, "Table");
            var row = El(tree, table, "TR");
            El(tree, row, "TD", "cell");
            El(tree, root, "P", "para");
        }));
        var tree = StructureTree.Read(tab.Document)!;
        var table = TagEdits.TableOf("Row", "2", "3", "a1, b2", out string? problem);
        Assert.Null(problem);

        var cell = TagEdits.Apply(tab, TagPath.Of(tree, Titled(tree, "cell")), "Change tag", (t, k) =>
            TagEdits.SetProperties(t, (StructElement)k!, new TagProperties("TH", "Head", "Alt words", "Spoken", "tr-TR", table)));
        var para = TagEdits.Apply(tab, TagPath.Of(tree, Titled(tree, "para")), "Change tag", (t, k) =>
            TagEdits.SetProperties(t, (StructElement)k!, new TagProperties("Intro", "para", "", "", "", null)));

        Assert.Equal(TagResult.Done, cell.Result);
        Assert.Equal(TagResult.Done, para.Result);
        var again = StructureTree.Read(tab.Document)!;
        var th = Titled(again, "Head");
        Assert.Equal(("TH", "Alt words", "Spoken", "tr-TR"), (th.Type, th.Alt, th.ActualText, th.Lang));
        var attributes = again.GetTableAttributes(th);
        Assert.Equal((TableScope.Row, 2, 3), (attributes.Scope, attributes.RowSpan, attributes.ColSpan));
        Assert.Equal(["a1", "b2"], attributes.Headers);
        Assert.Equal("P", again.StandardType(Titled(again, "para").Type));
        Assert.Equal("Intro", Titled(again, "para").Type);
        Assert.Equal("P", again.RoleMap["Intro"]);
    }

    [Fact]
    public void ATypeThatDoesNotFitItsParentIsRefusedAndWritesNothing()
    {
        using var tab = Open(Three());
        var tree = StructureTree.Read(tab.Document)!;
        var one = Titled(tree, "one");

        string? shown = TagEdits.TypeRefusal(tree, one, "TD");
        var outcome = TagEdits.Apply(tab, TagPath.Of(tree, one), "Change tag", (t, k) =>
            TagEdits.SetProperties(t, (StructElement)k!, new TagProperties("TD", "one", "", "", "", null)));

        Assert.Equal(AccessibilityText.PlacementReason(TagRules.NeedsRow), shown);
        Assert.Equal((TagResult.Refused, shown), (outcome.Result, outcome.Reason));
        Assert.Equal("P", Titled(StructureTree.Read(tab.Document)!, "one").Type);
        Assert.Equal(Loc.T("The type is empty."), TagEdits.TypeRefusal(tree, one, "  "));
    }

    [Theory]
    [InlineData("0", true)]
    [InlineData("x", true)]
    [InlineData("-2", true)]
    [InlineData("2", false)]
    [InlineData("", false)]
    public void ASpanIsAWholeNumberFromOne(string span, bool refused)
    {
        var table = TagEdits.TableOf("", span, "", "", out string? problem);

        Assert.Equal(refused, problem is not null);
        Assert.Equal(refused, table is null);
    }

    [Fact]
    public void ALanguageThatIsNotATagIsRefused()
    {
        using var tab = Open(Three());
        var tree = StructureTree.Read(tab.Document)!;

        var outcome = TagEdits.Apply(tab, TagPath.Of(tree, Titled(tree, "one")), "Change tag", (t, k) =>
            TagEdits.SetProperties(t, (StructElement)k!, new TagProperties("P", "one", "", "", "not a language", null)));

        Assert.Equal(TagResult.Refused, outcome.Result);
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public void ADropIsCheckedWithTheRuleAndPlacesTheNodeBesideOrInsideTheTarget()
    {
        using var tab = Open(Built((tree, root) =>
        {
            El(tree, root, "P", "one");
            El(tree, root, "P", "two");
            El(tree, root, "Sect", "sect");
            var table = El(tree, root, "Table", "table");
            El(tree, table, "TR", "row");
        }));
        var tree = StructureTree.Read(tab.Document)!;
        var (one, sect, table) = (Titled(tree, "one"), Titled(tree, "sect"), Titled(tree, "table"));

        Assert.Equal(AccessibilityText.PlacementReason(TagRules.TableKids), TagEdits.Drop(tree, one, table, DropZone.Into, false));
        Assert.Null(TagEdits.Drop(tree, one, sect, DropZone.Into, true));
        Assert.Equal(["two", "sect", "table"], Titles(tree.Roots[0]));
        Assert.Equal(["one"], Titles(sect));
        Assert.Null(TagEdits.Drop(tree, Titled(tree, "two"), sect, DropZone.After, true));
        Assert.Equal(["sect", "two", "table"], Titles(tree.Roots[0]));
        Assert.NotNull(TagEdits.Drop(tree, sect, Titled(tree, "one"), DropZone.Into, false));
    }

    [Fact]
    public void ADropFromTheTreeOnScreenIsTriedAgainstTheOpenDocumentsTree()
    {
        using var tab = Open(Three());
        var shown = StructureTree.Read(tab.Document)!;
        var (path, target) = (TagPath.Of(shown, Titled(shown, "one")), TagPath.Of(shown, Titled(shown, "three")));

        var outcome = TagEdits.Apply(tab, path, "Move tag", (t, k) => TagEdits.Drop(t, k!, target.Find(t)!, DropZone.After, true));

        Assert.Equal(TagResult.Done, outcome.Result);
        Assert.Equal(["two", "three", "one"], Titles(Titled(StructureTree.Read(tab.Document)!, "sect")));
    }

    [Fact]
    public void ANodeThatMovedSinceTheTreeWasReadIsNotTakenForAnother()
    {
        using var tab = Open(Three());
        var shown = StructureTree.Read(tab.Document)!;
        var path = TagPath.Of(shown, Titled(shown, "two"));
        Assert.Equal(TagResult.Done, Do(tab, "two", TagCommand.MoveDown).Result);

        var outcome = TagEdits.Apply(tab, path, "Move tag down", (t, k) => TagEdits.Run(t, k!, TagCommand.MoveDown));

        Assert.Equal(TagResult.Gone, outcome.Result);
        Assert.Equal("Move tag down", tab.Session.UndoLabel);
    }

    [Fact]
    public void DeletingAsArtifactTakesTheContentOutOfTheTreeAndTheReadingOrder()
    {
        using var tab = Open(Auto());
        var tree = StructureTree.Read(tab.Document)!;
        var paragraph = tree.Elements.First(e => e.Type == "P");
        string text = ReadingOrder.Export(tab.Document);
        int count = tree.Elements.Count();

        var outcome = TagEdits.Apply(tab, TagPath.Of(tree, paragraph), "Delete tag as artifact", (t, k) => TagEdits.Run(t, k!, TagCommand.DeleteAsArtifact));

        Assert.Equal(TagResult.Done, outcome.Result);
        Assert.Equal(count - 1, StructureTree.Read(tab.Document)!.Elements.Count());
        Assert.True(ReadingOrder.Export(tab.Document).Length < text.Length);
        Assert.True(tab.Undo());
        Assert.Equal(text, ReadingOrder.Export(tab.Document));
    }

    [Fact]
    public void MarkingOneContentNodeAsArtifactLeavesItsElementsOtherContent()
    {
        using var tab = Open(Auto());
        var tree = StructureTree.Read(tab.Document)!;
        var content = tree.Contents.First();
        Assert.True(TagEdits.Applies(tree, content, TagCommand.MarkAsArtifact));
        int count = tree.Contents.Count();

        var outcome = TagEdits.Apply(tab, TagPath.Of(tree, content), "Mark as artifact", (t, k) => TagEdits.Run(t, k!, TagCommand.MarkAsArtifact));

        Assert.Equal(TagResult.Done, outcome.Result);
        Assert.Equal(count - 1, StructureTree.Read(tab.Document)!.Contents.Count());
    }

    [Fact]
    public void ATextSelectionIsTaggedAsANewElementUnderTheChosenOne()
    {
        using var tab = Open(Auto());
        var tree = StructureTree.Read(tab.Document)!;
        var line = WholePage(tab);
        var runs = new[] { new SelectedRun(0, line, "text", []) };
        int paragraphs = tree.Elements.Count(e => e.Type == "P");

        var outcome = TagEdits.Apply(tab, TagPath.Of(tree, tree.Roots[0]), "Tag selection", (t, k) => TagEdits.TagSelection(t, k, "Div", runs));

        Assert.True(outcome.Result == TagResult.Done, outcome.Reason);
        var again = StructureTree.Read(tab.Document)!;
        var div = Assert.Single(again.Elements, e => e.Type == "Div");
        Assert.Same(again.Roots[0], div.Parent);
        Assert.NotEmpty(div.Kids);
        Assert.Equal("Tag selection", tab.Session.UndoLabel);
        Assert.True(again.Elements.Count(e => e.Type == "P") < paragraphs);
    }

    [Fact]
    public void ATextSelectionCanBeMarkedAsArtifactInOneStep()
    {
        using var tab = Open(Auto());
        var tree = StructureTree.Read(tab.Document)!;
        var line = WholePage(tab);
        int count = tree.Contents.Count();
        string text = ReadingOrder.Export(tab.Document);

        var outcome = TagEdits.Apply(tab, null, "Mark as artifact", (t, _) => TagEdits.SelectionAsArtifact(t, [new SelectedRun(0, line, "text", [])]));

        Assert.True(outcome.Result == TagResult.Done, outcome.Reason);
        Assert.True(StructureTree.Read(tab.Document)!.Contents.Count() < count);
        Assert.True(ReadingOrder.Export(tab.Document).Length < text.Length);
        Assert.Equal("Mark as artifact", tab.Session.UndoLabel);
    }

    [Fact]
    public void ASelectionNothingCanBeTaggedFromIsRefusedWithItsReason()
    {
        using var tab = Open(Auto());
        var tree = StructureTree.Read(tab.Document)!;

        var outcome = TagEdits.Apply(tab, TagPath.Of(tree, tree.Roots[0]), "Tag selection", (t, k) => TagEdits.TagSelection(t, k, "Div", []));

        Assert.Equal((TagResult.Refused, AccessibilityText.ContentReason(TagContent.EmptySelection)), (outcome.Result, outcome.Reason));
    }

    [Fact]
    public void ARestrictedOrEncryptedFileIsReadOnlyAndNothingIsWritten()
    {
        var document = PdfDocument.Open(Auto());
        using var restricted = Open(Restricted());
        var open = PdfSecurity.Create("", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, document.FirstId ?? []);
        using var encrypted = Open(document.SaveRewrite(new PdfSaveOptions(Security: open)));

        foreach (var tab in new[] { restricted, encrypted })
        {
            var tree = StructureTree.Read(tab.Document)!;
            Assert.NotNull(TagEdits.ReadOnlyReason(tab.Document, tree));
            var outcome = TagEdits.Apply(tab, TagPath.Of(tree, tree.Roots[0]), "Move tag down", (t, k) => TagEdits.Run(t, k!, TagCommand.MoveUp));
            Assert.Equal(TagResult.Refused, outcome.Result);
            Assert.False(tab.IsDirty);
        }
    }

    [Fact]
    public void ATreeTooDeepToReadWholeIsNeverWritten()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var tree = StructureTree.Create(document);
        StructElement? parent = null;
        for (int i = 0; i < 140; i++) parent = El(tree, parent, "Div", "d" + i);
        tree.Write(document);
        using var tab = Open(document.SaveRewrite(new PdfSaveOptions()));
        var shown = StructureTree.Read(tab.Document)!;

        Assert.True(shown.IsTruncated);
        Assert.NotNull(TagEdits.ReadOnlyReason(tab.Document, shown));
        var outcome = TagEdits.Apply(tab, TagPath.Of(shown, shown.Roots[0]), "Delete tag", (t, k) => TagEdits.Run(t, k!, TagCommand.Delete));
        Assert.Equal(TagResult.Refused, outcome.Result);
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public void TheFilterKeepsMatchesAndTheTagsAboveThem()
    {
        using var tab = Open(Built((tree, root) =>
        {
            var sect = El(tree, root, "Sect", "intro");
            El(tree, sect, "P", "plain");
            El(tree, sect, "H2", "Chapter one");
            var table = El(tree, root, "Table", "data");
            El(tree, table, "TR", "row");
            El(tree, root, "Figure").Alt = "A grey square";
        }));
        var tree = StructureTree.Read(tab.Document)!;

        var byType = TagFilter.Of(tree, "h2")!;
        var byText = TagFilter.Of(tree, " SQUARE ")!;
        var byMap = TagFilter.Of(tree, "Table")!;

        Assert.Equal(1, byType.Matches);
        Assert.Equal(["Document", "H2", "Sect"], byType.Shown.Select(e => e.Type).Order().ToList());
        Assert.Equal(["Document", "Figure"], byText.Shown.Select(e => e.Type).Order().ToList());
        Assert.Equal(1, byMap.Matches);
        Assert.Null(TagFilter.Of(tree, "  "));
        Assert.Equal(0, TagFilter.Of(tree, "nothing like it")!.Matches);
    }

    [Fact]
    public void TheFilterStopsAtItsLimitAndSaysSo()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var tree = StructureTree.Create(document);
        var root = El(tree, null, "Document");
        for (int i = 0; i < TagFilter.Limit + 20; i++) El(tree, root, "P", "word " + i);

        var all = TagFilter.Of(tree, "word")!;

        Assert.True(all.IsCapped);
        Assert.Equal(TagFilter.Limit, all.Matches);
        Assert.False(TagFilter.Of(tree, "word 1")!.IsCapped);
    }
}
