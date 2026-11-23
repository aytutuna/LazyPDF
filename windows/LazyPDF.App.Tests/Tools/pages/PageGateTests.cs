using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.App.Tests.PagesKit;

namespace LazyPDF.App.Tests;

// A restricted file refuses the page edits of the organize view and the inspector, a signed one asks first.
[Collection("Application")]
public sealed class PageGateTests
{
    private static DocumentTab Restricted()
    {
        var document = PdfDocument.Open(Pdfs.Text(4));
        var security = PdfSecurity.Create("", "owner", PdfPermissions.Print, PdfCryptStrength.Aes256, document.FirstId ?? []);
        return new DocumentTab(PdfEditSession.Open(document.SaveRewrite(new PdfSaveOptions(Security: security))), new FakeRenderer(), null, "locked.pdf");
    }

    private static DocumentTab Signed() =>
        new(PdfEditSession.Open(StampsPanelTests.Signed(false, 4)), new FakeRenderer(), null, "signed.pdf");

    private static void Click(FrameworkElement owner, string name) =>
        ((ButtonBase)owner.FindName(name)).RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

    // Each edit as one gesture on the organize view.
    private static readonly (string Name, Func<Shown, DocumentTab, string, Task> Run)[] OrganizeEdits =
    [
        ("turn", (s, _, _) => { s.Select(1); s.Click("TurnLeft"); return Task.CompletedTask; }),
        ("remove", (s, _, _) => { s.Select(1); s.Click("Remove"); return Task.CompletedTask; }),
        ("duplicate", (s, _, _) => { s.Select(1); s.Click("Duplicate"); return Task.CompletedTask; }),
        ("nudge", (s, _, _) => { s.Select(1); s.View.Press(Key.Right, ModifierKeys.Control); return Task.CompletedTask; }),
        ("blank", (s, _, _) => { s.Select(1); s.Click("Blank"); return Task.CompletedTask; }),
        ("paste", (s, _, _) =>
        {
            PageClipboard.Set(Pdfs.Text(1, "Pasted"), 1);
            s.Select(1);
            s.View.Press(Key.V, ModifierKeys.Control);
            return Task.CompletedTask;
        }),
        ("move", (s, tab, _) =>
        {
            var data = new DataObject(PageDrag.Format, new PagePayload(tab, [3], tab.Revision));
            var at = new Point(20, 20);
            s.Grid.RaiseEvent(DragArgs(UIElement.DragOverEvent, data, s.Grid, at));
            s.Grid.RaiseEvent(DragArgs(UIElement.DropEvent, data, s.Grid, at));
            return Task.CompletedTask;
        }),
        ("files", (s, _, file) => s.View.InsertFilesAsync([file], 1)),
    ];

    public static TheoryData<string> OrganizeNames()
    {
        var names = new TheoryData<string>();
        foreach (var (name, _) in OrganizeEdits) names.Add(name);
        return names;
    }

    [Theory]
    [MemberData(nameof(OrganizeNames))]
    public Task OrganizeRefusesARestrictedFile(string name) => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        string file = dir.File("extra.pdf", Pdfs.Text(1, "Dropped"));
        using var tab = Restricted();
        var host = new StageHost();
        using var shown = new Shown(tab, host);
        int revision = tab.Revision;

        await OrganizeEdits.Single(e => e.Name == name).Run(shown, tab, file);

        Assert.Equal(revision, tab.Revision);
        Assert.Equal("This file cannot be changed", Assert.Single(host.Problems).Title);
    });

    [Theory]
    [MemberData(nameof(OrganizeNames))]
    public Task OrganizeAsksBeforeChangingASignedFile(string name) => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        string file = dir.File("extra.pdf", Pdfs.Text(1, "Dropped"));
        using var tab = Signed();
        var host = new StageHost();
        using var shown = new Shown(tab, host);
        int revision = tab.Revision;

        await OrganizeEdits.Single(e => e.Name == name).Run(shown, tab, file);

        Assert.Equal(revision, tab.Revision);
        Assert.Equal("Check before going on", Assert.Single(host.Notices));
        host.Actions[0]!.Run();
        await Sta.Until(() => tab.Revision > revision);
        Assert.Single(host.Notices);
        Assert.Empty(host.Problems);
    });

    private static (PagesPanel Panel, ListBox Thumbs) Inspect(DocumentTab tab, StageHost host)
    {
        var panel = new PagesPanel();
        panel.Attach(tab, FakeViewer.Create().Viewer, host);
        var thumbs = (ListBox)panel.FindName("Thumbs");
        thumbs.SelectedItems.Add(((List<PageCell>)thumbs.ItemsSource)[1]);
        return (panel, thumbs);
    }

    [Theory]
    [InlineData("TurnLeft")]
    [InlineData("Copy")]
    [InlineData("Remove")]
    [InlineData("Later")]
    [InlineData("Blank")]
    public Task TheInspectorRefusesARestrictedFile(string button) => Sta.Run(() =>
    {
        using var tab = Restricted();
        var host = new StageHost();
        var (panel, _) = Inspect(tab, host);
        int revision = tab.Revision;

        Click(panel, button);

        Assert.Equal(revision, tab.Revision);
        Assert.Equal("This file cannot be changed", Assert.Single(host.Problems).Title);
        panel.Detach();
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData("TurnLeft")]
    [InlineData("Copy")]
    [InlineData("Remove")]
    [InlineData("Later")]
    [InlineData("Blank")]
    public Task TheInspectorAsksBeforeChangingASignedFile(string button) => Sta.Run(async () =>
    {
        using var tab = Signed();
        var host = new StageHost();
        var (panel, _) = Inspect(tab, host);
        int revision = tab.Revision;

        Click(panel, button);

        Assert.Equal(revision, tab.Revision);
        Assert.Equal("Check before going on", Assert.Single(host.Notices));
        host.Actions[0]!.Run();
        await Sta.Until(() => tab.Revision > revision);
        Assert.Single(host.Notices);
        Assert.Empty(host.Problems);
        panel.Detach();
    });
}
