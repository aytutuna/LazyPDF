using System.Windows.Automation;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Accessibility;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The tag tree of the panel: what picking a node does, the editor beside it, the commands, the filter and the read-only case.
[Collection("Application")]
public sealed class TagTreePanelTests
{
    private sealed record Shown(AccessibilityPanel Panel, DocumentTab Tab, FakeViewer Viewer, PageOverlay Overlay, RecordingHost Host);

    private static async Task<Shown> Show(byte[] bytes)
    {
        var tab = TagEditsTests.Open(bytes);
        var host = new RecordingHost();
        var (viewer, overlay) = FakeViewer.Create();
        var panel = new AccessibilityPanel();
        panel.Attach(tab, viewer, host);
        panel.ShowTags.IsChecked = true;
        await Sta.Until(() => panel.TagTree.Items.Count > 0);
        return new Shown(panel, tab, (FakeViewer)(object)viewer, overlay, host);
    }

    private static byte[] Three() => TagEditsTests.Built((tree, root) =>
    {
        var sect = TagEditsTests.El(tree, root, "Sect", "sect");
        TagEditsTests.El(tree, sect, "P", "one");
        TagEditsTests.El(tree, sect, "P", "two");
        TagEditsTests.El(tree, sect, "P", "three");
    });

    private static TreeViewItem? Find(ItemsControl parent, string title)
    {
        foreach (var item in parent.Items.OfType<TreeViewItem>())
        {
            if (item.Tag is not StructElement element) continue;
            if (element.Title == title) return item;
            if (element.Kids.Count == 0) continue;
            item.IsExpanded = true;
            if (Find(item, title) is { } found) return found;
        }
        return null;
    }

    private static IReadOnlyList<string?> Titles(TreeViewItem item) => item.Items.OfType<TreeViewItem>().Select(i => (i.Tag as StructElement)?.Title).ToList();

    private static async Task<string?> Reloaded(Shown s, TreeViewItem old)
    {
        await Sta.Until(() => s.Panel.TagTree.SelectedItem is TreeViewItem now && !ReferenceEquals(now, old));
        return ((TreeViewItem)s.Panel.TagTree.SelectedItem).Tag is StructElement e ? e.Title : null;
    }

    [Fact]
    public Task AMoveFromThePanelIsOneStepAndTheTreeComesBackWithTheSameNodeAndOpenTags() => Sta.Run(async () =>
    {
        var s = await Show(Three());
        var two = Find(s.Panel.TagTree, "two")!;
        two.IsSelected = true;

        await s.Panel.RunTagCommandAsync(TagCommand.MoveDown);
        string? picked = await Reloaded(s, two);

        Assert.Equal("Move tag down", s.Tab.Session.UndoLabel);
        Assert.Equal("two", picked);
        var sect = Find(s.Panel.TagTree, "sect")!;
        Assert.True(sect.IsExpanded);
        Assert.Equal(["one", "three", "two"], Titles(sect));
    });

    [Fact]
    public Task EveryNodeAndControlOfTheEditorHasANameForAScreenReader() => Sta.Run(async () =>
    {
        var s = await Show(Three());
        var one = Find(s.Panel.TagTree, "one")!;
        one.IsSelected = true;

        Assert.Contains("one", AutomationProperties.GetName(one));
        foreach (var control in new System.Windows.FrameworkElement[]
        {
            s.Panel.TagTree, s.Panel.TagFilterBox, s.Panel.TagType, s.Panel.TagTitle, s.Panel.TagAlt, s.Panel.TagActual, s.Panel.TagLang,
            s.Panel.TagApply, s.Panel.TagUp, s.Panel.TagDown, s.Panel.TagIndent, s.Panel.TagOutdent, s.Panel.TagDelete, s.Panel.TagDeleteArtifact,
            s.Panel.TagArtifact, s.Panel.TagHeaderRow, s.Panel.TagAs, s.Panel.TagSelect, s.Panel.TagDraw, s.Panel.TagSelectionArtifact,
        })
            Assert.False(string.IsNullOrWhiteSpace(AutomationProperties.GetName(control)), control.GetType().Name);
    });

    [Fact]
    public Task TheEditorShowsTheRulesReasonBesideTheFieldAndAppliesAValidChange() => Sta.Run(async () =>
    {
        var s = await Show(Three());
        var one = Find(s.Panel.TagTree, "one")!;
        one.IsSelected = true;
        Assert.False(s.Panel.TagApply.IsEnabled);

        s.Panel.TagType.Text = "TD";
        s.Panel.TagTitle.Text = "first";

        Assert.Equal(AccessibilityText.PlacementReason(TagRules.NeedsRow), s.Panel.TagFieldMessage.Text);
        Assert.False(s.Panel.TagApply.IsEnabled);

        s.Panel.TagType.Text = "H2";
        Assert.Equal("", s.Panel.TagFieldMessage.Text);
        Assert.True(s.Panel.TagApply.IsEnabled);
        await s.Panel.ApplyFieldsAsync();

        Assert.Equal("Change tag", s.Tab.Session.UndoLabel);
        var written = StructureTree.Read(s.Tab.Document)!.Elements.First(e => e.Title == "first");
        Assert.Equal("H2", written.Type);
    });

    [Fact]
    public Task TheTableFieldsShowOnlyForCells() => Sta.Run(async () =>
    {
        var s = await Show(TagEditsTests.Built((tree, root) =>
        {
            var row = TagEditsTests.El(tree, TagEditsTests.El(tree, root, "Table"), "TR");
            TagEditsTests.El(tree, row, "TD", "cell");
        }));

        Find(s.Panel.TagTree, "cell")!.IsSelected = true;
        Assert.Equal(System.Windows.Visibility.Visible, s.Panel.TagCell.Visibility);

        ((TreeViewItem)s.Panel.TagTree.Items[0]).IsSelected = true;
        Assert.Equal(System.Windows.Visibility.Collapsed, s.Panel.TagCell.Visibility);
    });

    [Fact]
    public Task APickedElementIsOutlinedOnThePageAndTheOutlineGoesWhenItIsLeft() => Sta.Run(async () =>
    {
        var s = await Show(TagEditsTests.Auto());
        var paragraph = FirstOf(s.Panel.TagTree, "P")!;

        paragraph.IsSelected = true;
        await Sta.Until(() => s.Overlay.Children.Count > 0);

        paragraph.IsSelected = false;
        await Sta.Until(() => s.Overlay.Children.Count == 0);
    });

    private static TreeViewItem? FirstOf(ItemsControl parent, string type)
    {
        foreach (var item in parent.Items.OfType<TreeViewItem>())
        {
            if (item.Tag is not StructElement element) continue;
            if (element.Type == type) return item;
            if (element.Kids.Count == 0) continue;
            item.IsExpanded = true;
            if (FirstOf(item, type) is { } found) return found;
        }
        return null;
    }

    [Fact]
    public Task MarkedContentIsAListedNodeThatCanBeMarkedAsArtifact() => Sta.Run(async () =>
    {
        var s = await Show(TagEditsTests.Auto());
        var paragraph = FirstOf(s.Panel.TagTree, "P")!;
        paragraph.IsExpanded = true;
        var content = (TreeViewItem)paragraph.Items[0];
        content.IsSelected = true;

        Assert.StartsWith(Loc.T("Marked content, page {0}", 1), AutomationProperties.GetName(content));
        Assert.True(s.Panel.TagArtifact.IsEnabled);
        Assert.False(s.Panel.TagDelete.IsEnabled);
        Assert.Equal(System.Windows.Visibility.Collapsed, s.Panel.TagEditor.Visibility);
        int before = StructureTree.Read(s.Tab.Document)!.Contents.Count();

        await s.Panel.RunTagCommandAsync(TagCommand.MarkAsArtifact);

        Assert.Equal("Mark as artifact", s.Tab.Session.UndoLabel);
        Assert.Equal(before - 1, StructureTree.Read(s.Tab.Document)!.Contents.Count());
    });

    [Fact]
    public Task ThePagesTextSelectionIsTaggedUnderThePickedElement() => Sta.Run(async () =>
    {
        var s = await Show(TagEditsTests.Auto());
        var range = new TextRange(0, TextPage.Create(s.Tab.Document, s.Tab.Document.Pages[0]).Chars.Count);
        s.Viewer.Select(new SelectedRun(0, range, "text", []));
        ((TreeViewItem)s.Panel.TagTree.Items[0]).IsSelected = true;
        s.Panel.TagAs.Text = "Div";

        await s.Panel.TagSelectionAsync();

        Assert.Equal("Tag selection", s.Tab.Session.UndoLabel);
        Assert.Contains(StructureTree.Read(s.Tab.Document)!.Elements, e => e.Type == "Div");
    });

    [Fact]
    public Task WithoutASelectionTaggingItSaysSoAndChangesNothing() => Sta.Run(async () =>
    {
        var s = await Show(TagEditsTests.Auto());
        ((TreeViewItem)s.Panel.TagTree.Items[0]).IsSelected = true;

        await s.Panel.TagSelectionAsync();

        Assert.Equal(Loc.T("Select the text on the page first."), s.Panel.TagMessage.Text);
        Assert.False(s.Tab.IsDirty);
    });

    [Fact]
    public Task TheFilterShowsMatchesWithTheirParentsOpenAndTheWholeTreeAgainWhenCleared() => Sta.Run(async () =>
    {
        var s = await Show(TagEditsTests.Built((tree, root) =>
        {
            var sect = TagEditsTests.El(tree, root, "Sect", "intro");
            TagEditsTests.El(tree, sect, "P", "plain");
            TagEditsTests.El(tree, root, "Figure").Alt = "A grey square";
        }));

        s.Panel.TagFilterBox.Text = "square";

        var top = (TreeViewItem)Assert.Single(s.Panel.TagTree.Items);
        Assert.True(top.IsExpanded);
        var figure = Assert.Single(top.Items.OfType<TreeViewItem>());
        Assert.Equal("Figure", ((StructElement)figure.Tag).Type);
        Assert.Equal(Loc.T("{0} tags match.", 1), s.Panel.TagsNote.Text);

        s.Panel.TagFilterBox.Text = "";

        Assert.Equal(["intro", null], Titles((TreeViewItem)s.Panel.TagTree.Items[0]));
        Assert.Equal(Loc.T("{0} tags. Pick one to go to its page.", 4), s.Panel.TagsNote.Text);
    });

    [Fact]
    public Task ARestrictedFileShowsWhyItIsReadOnlyAndTheCommandsDoNothing() => Sta.Run(async () =>
    {
        var s = await Show(TagEditsTests.Restricted());
        var node = FirstOf(s.Panel.TagTree, "P")!;
        node.IsSelected = true;

        Assert.Equal(System.Windows.Visibility.Visible, s.Panel.TagsReadOnlyRow.Visibility);
        Assert.False(string.IsNullOrEmpty(s.Panel.TagsReadOnly.Text));
        Assert.False(s.Panel.TagDown.IsEnabled);
        Assert.False(s.Panel.TagEditor.IsEnabled);

        await s.Panel.RunTagCommandAsync(TagCommand.MoveDown);

        Assert.Equal(s.Panel.TagsReadOnly.Text, s.Panel.TagMessage.Text);
        Assert.False(s.Tab.IsDirty);
    });
}
