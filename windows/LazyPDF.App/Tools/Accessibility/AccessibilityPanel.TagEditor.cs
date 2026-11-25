using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.App.Viewer;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

// Changing the tags: the fields of the picked element, the commands on a node, dragging nodes and tagging what the page shows.
public partial class AccessibilityPanel
{
    private const string DragFormat = "LazyPDF.TagNode";

    private static readonly string[] Scopes = ["", "Row", "Column", "Both"];

    private string? _tagReadOnly;
    private bool _loadingFields;
    private TagProperties? _loaded;
    private TreeViewItem? _dragItem;
    private Point _dragFrom;
    private IPagePointerTool? _drawTool;

    private static bool IsCell(StructureTree tree, StructElement element) => tree.StandardType(element.Type) is "TH" or "TD";

    private void Say(string text)
    {
        TagMessage.Text = text;
        Host?.SetStatus(text);
    }

    private void ShowTagEditor(StructKid? kid)
    {
        TagMessage.Text = "";
        UpdateTagButtons(kid);
        if (kid is not StructElement element || _tree is not { } tree)
        {
            TagEditor.Visibility = Visibility.Collapsed;
            _loaded = null;
            return;
        }
        _loadingFields = true;
        TagType.Text = element.Type;
        TagTitle.Text = element.Title ?? "";
        TagAlt.Text = element.Alt ?? "";
        TagActual.Text = element.ActualText ?? "";
        TagLang.Text = element.Lang ?? "";
        bool cell = IsCell(tree, element);
        TagCell.Visibility = cell ? Visibility.Visible : Visibility.Collapsed;
        if (cell)
        {
            var table = tree.GetTableAttributes(element);
            TagScope.SelectedIndex = table.Scope is { } scope ? (int)scope + 1 : 0;
            TagRowSpan.Text = table.RowSpan?.ToString() ?? "";
            TagColSpan.Text = table.ColSpan?.ToString() ?? "";
            TagHeaders.Text = string.Join(", ", table.Headers ?? []);
        }
        _loadingFields = false;
        TagEditor.IsEnabled = _tagReadOnly is null;
        TagEditor.Visibility = Visibility.Visible;
        _loaded = Fields(element);
        ValidateFields(element);
    }

    private TagProperties Fields(StructElement element)
    {
        TableAttributes? table = null;
        if (_tree is { } tree && IsCell(tree, element))
            table = TagEdits.TableOf(Scopes[Math.Max(TagScope.SelectedIndex, 0)], TagRowSpan.Text, TagColSpan.Text, TagHeaders.Text, out _);
        return new TagProperties(TagType.Text, TagTitle.Text, TagAlt.Text, TagActual.Text, TagLang.Text, table);
    }

    private static bool Same(TagProperties a, TagProperties b) =>
        a.Type == b.Type && a.Title == b.Title && a.Alt == b.Alt && a.ActualText == b.ActualText && a.Lang == b.Lang
        && (a.Table is null && b.Table is null
            || a.Table is not null && b.Table is not null && a.Table.Scope == b.Table.Scope && a.Table.RowSpan == b.Table.RowSpan
               && a.Table.ColSpan == b.Table.ColSpan && (a.Table.Headers ?? []).SequenceEqual(b.Table.Headers ?? []));

    private void TagField_Changed(object sender, RoutedEventArgs e)
    {
        if (!_loadingFields && SelectedKid is StructElement element) ValidateFields(element);
    }

    // The rules answer while the field is typed in, so the reason stands next to the field before anything is written.
    private void ValidateFields(StructElement element)
    {
        string? message = null;
        string type = TagType.Text.Trim();
        if (type != element.Type) message = TagEdits.TypeRefusal(_tree!, element, type);
        if (message is null && TagLang.Text.Trim() is { Length: > 0 } lang && !AccessibilityEdits.IsLanguageTag(lang))
            message = Loc.T("Write the language as a tag such as en-US or tr-TR.");
        if (message is null && IsCell(_tree!, element)) TagEdits.TableOf(Scopes[Math.Max(TagScope.SelectedIndex, 0)], TagRowSpan.Text, TagColSpan.Text, TagHeaders.Text, out message);
        TagFieldMessage.Text = message ?? "";
        TagApply.IsEnabled = _tagReadOnly is null && message is null && _loaded is { } loaded && !Same(loaded, Fields(element));
    }

    private async void TagApply_Click(object sender, RoutedEventArgs e) => await ApplyFieldsAsync();

    private void TagEditor_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || !TagApply.IsEnabled) return;
        e.Handled = true;
        _ = ApplyFieldsAsync();
    }

    internal async Task ApplyFieldsAsync()
    {
        if (SelectedKid is not StructElement element || !TagApply.IsEnabled) return;
        var fields = Fields(element);
        await EditTagAsync(Loc.T("Change tag"), element, (tree, kid) => TagEdits.SetProperties(tree, (StructElement)kid!, fields));
    }

    private void UpdateTagButtons(StructKid? kid)
    {
        foreach (var button in TagButtons.Children.OfType<Button>())
            button.IsEnabled = _tagReadOnly is null && kid is not null && _tree is { } tree && Command(button) is { } command && TagEdits.Applies(tree, kid, command);
        TagSelectionTools.IsEnabled = _tagReadOnly is null;
    }

    private static TagCommand? Command(FrameworkElement element) =>
        element.Tag is string name && Enum.TryParse<TagCommand>(name, out var command) ? command : null;

    private void TagMenu_Opened(object sender, RoutedEventArgs e)
    {
        var kid = SelectedKid;
        foreach (var item in TagMenu.Items.OfType<MenuItem>())
            item.IsEnabled = _tagReadOnly is null && kid is not null && _tree is { } tree && Command(item) is { } command && TagEdits.Applies(tree, kid, command);
    }

    private async void TagCommand_Click(object sender, RoutedEventArgs e)
    {
        if (Command((FrameworkElement)sender) is { } command) await RunTagCommandAsync(command);
    }

    internal async Task RunTagCommandAsync(TagCommand command)
    {
        if (SelectedKid is not { } kid || _tree is not { } tree) return;
        if (_tagReadOnly is { } why)
        {
            Say(why);
            return;
        }
        if (!TagEdits.Applies(tree, kid, command))
        {
            Say(Loc.T("That cannot be done to this tag."));
            return;
        }
        // The rule speaks before the edit, so a move that would break the nesting is never tried.
        if (TagEdits.Refusal(tree, kid, command) is { } reason)
        {
            Say(reason);
            return;
        }
        await EditTagAsync(TagEdits.Label(command), kid, (t, k) => TagEdits.Run(t, k!, command));
    }

    // One edit, one undo step: the open document's own tree is read again, the node found there, the tree written and committed.
    private async Task EditTagAsync(string label, StructKid? kid, Func<StructureTree, StructKid?, string?> edit)
    {
        if (Tab is not { } tab || Host is not { } host || _tree is not { } shown) return;
        if (_tagReadOnly is { } why)
        {
            Say(why);
            return;
        }
        var path = kid is null ? null : TagPath.Of(shown, kid);
        await ChangeGate.RunAsync(tab, host, label, () =>
        {
            if (!ReferenceEquals(tab, Tab)) return Task.CompletedTask;
            var outcome = TagEdits.Apply(tab, path, label, edit);
            switch (outcome.Result)
            {
                case TagResult.Done:
                    TagMessage.Text = "";
                    host.SetStatus(label + ".");
                    break;
                case TagResult.Unchanged:
                    host.SetStatus(Loc.T("Nothing to change."));
                    break;
                case TagResult.Refused:
                    Say(outcome.Reason!);
                    break;
                case TagResult.Gone:
                    Say(Loc.T("The tag is no longer in the file."));
                    break;
                default:
                    host.ShowProblem(new Problem(Loc.T("Tags not changed"), Loc.T("The tags of this file are too large to change here.")));
                    break;
            }
            return Task.CompletedTask;
        });
    }

    private void TagTree_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        TagCommand? command = (Keyboard.Modifiers, key) switch
        {
            (ModifierKeys.Alt, Key.Up) => TagCommand.MoveUp,
            (ModifierKeys.Alt, Key.Down) => TagCommand.MoveDown,
            (ModifierKeys.Alt, Key.Right) => TagCommand.Indent,
            (ModifierKeys.Alt, Key.Left) => TagCommand.Outdent,
            (ModifierKeys.None, Key.Delete) => TagCommand.Delete,
            (ModifierKeys.Control, Key.Delete) => TagCommand.DeleteAsArtifact,
            _ => null,
        };
        if (command is null) return;
        e.Handled = true;
        _ = RunTagCommandAsync(command.Value);
    }

    private static TreeViewItem? ItemAt(object? source)
    {
        var node = source as DependencyObject;
        while (node is not null and not TreeViewItem) node = node is Visual ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node);
        return node as TreeViewItem;
    }

    private void TagTree_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (ItemAt(e.OriginalSource) is not { } item) return;
        item.IsSelected = true;
        item.Focus();
    }

    private void TagTree_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _dragItem = ItemAt(e.OriginalSource);
        _dragFrom = e.GetPosition(TagTree);
    }

    private void TagTree_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _dragItem is not { Tag: StructKid kid } item || _tagReadOnly is not null) return;
        var now = e.GetPosition(TagTree);
        if (Math.Abs(now.X - _dragFrom.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(now.Y - _dragFrom.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _dragItem = null;
        DragDrop.DoDragDrop(item, new DataObject(DragFormat, kid), DragDropEffects.Move);
    }

    private (StructKid Kid, StructKid Target, DropZone Zone)? DropPlan(DragEventArgs e)
    {
        if (e.Data.GetData(DragFormat) is not StructKid kid || ItemAt(e.OriginalSource) is not { Tag: StructKid target } item) return null;
        var header = item.Template?.FindName("PART_Header", item) as FrameworkElement ?? item;
        double y = e.GetPosition(header).Y, height = Math.Max(header.ActualHeight, 1);
        return (kid, target, y < height / 4 ? DropZone.Before : y > height * 3 / 4 ? DropZone.After : DropZone.Into);
    }

    private void TagTree_DragOver(object sender, DragEventArgs e)
    {
        e.Handled = true;
        e.Effects = DragDropEffects.None;
        if (_tree is not { } tree || _tagReadOnly is not null || DropPlan(e) is not var (kid, target, zone)) return;
        string? reason = TagEdits.Drop(tree, kid, target, zone, false);
        TagMessage.Text = reason ?? "";
        if (reason is null) e.Effects = DragDropEffects.Move;
    }

    private async void TagTree_Drop(object sender, DragEventArgs e)
    {
        e.Handled = true;
        if (_tree is not { } tree || DropPlan(e) is not var (kid, target, zone)) return;
        if (TagEdits.Drop(tree, kid, target, zone, false) is { } reason)
        {
            Say(reason);
            return;
        }
        var to = TagPath.Of(tree, target);
        await EditTagAsync(Loc.T("Move tag"), kid, (t, k) => to.Find(t) is { } found ? TagEdits.Drop(t, k!, found, zone, true) : Loc.T("The tag is no longer in the file."));
    }

    // The page's text selection, or a box drawn on the page, becomes a new tag of the chosen type under the picked element.
    private async void TagSelection_Click(object sender, RoutedEventArgs e) => await TagSelectionAsync();

    private async Task<IReadOnlyList<SelectedRun>?> SelectionAsync()
    {
        if (Viewer is not { HasSelection: true } viewer)
        {
            Say(Loc.T("Select the text on the page first."));
            return null;
        }
        return await viewer.GetSelectionAsync();
    }

    private bool TypeToTag(out string type)
    {
        type = TagAs.Text.Trim();
        if (type.Length > 0) return true;
        Say(Loc.T("The type is empty."));
        return false;
    }

    internal async Task TagSelectionAsync()
    {
        if (!TypeToTag(out string type) || await SelectionAsync() is not { } runs) return;
        await EditTagAsync(Loc.T("Tag selection"), SelectedKid, (tree, kid) => TagEdits.TagSelection(tree, kid, type, runs));
    }

    private async void TagSelectionArtifact_Click(object sender, RoutedEventArgs e)
    {
        if (await SelectionAsync() is not { } runs) return;
        await EditTagAsync(Loc.T("Mark as artifact"), null, (tree, _) => TagEdits.SelectionAsArtifact(tree, runs));
    }

    private void TagDraw_Click(object sender, RoutedEventArgs e)
    {
        if (Viewer is not { } viewer || !TypeToTag(out _)) return;
        StopDraw();
        _drawTool = new SignatureBoxTool(viewer, AreaDrawn, StopDraw);
        viewer.PointerTool = _drawTool;
        Say(Loc.T("Drag on the page over what to tag."));
    }

    private void AreaDrawn(int page, Rect box)
    {
        var viewer = Viewer;
        StopDraw();
        if (viewer is null || !TypeToTag(out string type)) return;
        _ = TagAreaAsync(page, viewer.Geometry(page).ToUser(new DisplayRect(box.X, box.Y, box.Width, box.Height)), type);
    }

    internal Task TagAreaAsync(int page, PdfRect area, string type) =>
        EditTagAsync(Loc.T("Tag area"), SelectedKid, (tree, kid) => TagEdits.TagArea(tree, kid, type, page, area));

    private void StopDraw()
    {
        if (_drawTool is not { } tool) return;
        _drawTool = null;
        if (ReferenceEquals(Viewer?.PointerTool, tool)) Viewer!.PointerTool = null;
    }
}
