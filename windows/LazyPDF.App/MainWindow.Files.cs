// Opening and saving with the file dialogs, dropping files on the window, and printing.

using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;

namespace LazyPDF.App;

public partial class MainWindow
{
    private void Open_Click(object sender, RoutedEventArgs e) => OpenWithDialog();

    private void OpenWithDialog()
    {
        var dialog = new OpenFileDialog
        {
            Multiselect = true,
            Filter = FileKinds.OpenFilter(Loc.T("PDF files"), Loc.T("Pictures"), Loc.T("Text files"), Loc.T("All supported files")),
        };
        if (dialog.ShowDialog(this) == true) _ = _vm.OpenFilesAsync(dialog.FileNames);
    }

    private void Save_Click(object sender, RoutedEventArgs e) => SaveWithDialog();

    private void SaveWithDialog()
    {
        if (_vm.ActiveDocument is not { } tab || _inspectorPanel?.HandIn() == false) return;
        if (AppViewModel.NeedsName(tab)) SaveAsWithDialog();
        else _vm.Save(tab);
    }

    private void SaveAs_Click(object sender, RoutedEventArgs e) => SaveAsWithDialog();

    private bool SaveAsWithDialog()
    {
        if (_inspectorPanel?.HandIn() == false || _vm.ActiveDocument is not { } tab || AskForPath(tab, Loc.T("Save as")) is not { } path) return false;
        return _vm.SaveAs(tab, path);
    }

    private void SaveCompact_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.ActiveDocument is not { } tab || _inspectorPanel?.HandIn() == false) return;
        if (tab.Document.IsSigned)
        {
            _vm.ShowNotice(Loc.T("Signatures would be lost"), Loc.T("{0} is signed. Saving it compact writes it again and the signatures no longer hold. Save and Save as keep them.", tab.Title),
                new NoticeAction(Loc.T("Save compact anyway"), () => SaveCompactWithDialog(tab)));
            return;
        }
        SaveCompactWithDialog(tab);
    }

    private void SaveCompactWithDialog(DocumentTab tab)
    {
        if (AskForPath(tab, Loc.T("Save compact")) is { } path) _vm.SaveCompact(tab, path);
    }

    private string? AskForPath(DocumentTab tab, string title)
    {
        var dialog = new SaveFileDialog
        {
            Title = title,
            Filter = Loc.T("PDF files") + "|*.pdf",
            DefaultExt = ".pdf",
            AddExtension = true,
            OverwritePrompt = true,
            FileName = System.IO.Path.GetFileNameWithoutExtension(tab.Title),
            InitialDirectory = tab.Path is { } path ? System.IO.Path.GetDirectoryName(path) : null,
        };
        return dialog.ShowDialog(this) == true ? dialog.FileName : null;
    }

    private void SaveMenu_Click(object sender, RoutedEventArgs e)
    {
        bool open = _vm.ActiveDocument is not null;
        SaveAsItem.IsEnabled = SaveCompactItem.IsEnabled = open;
        SaveMenu.PlacementTarget = SaveMenuButton;
        SaveMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        SaveMenu.IsOpen = true;
    }

    private void Undo_Click(object sender, RoutedEventArgs e) => Undo();

    private void Redo_Click(object sender, RoutedEventArgs e) => Redo();

    private void Undo()
    {
        _inspectorPanel?.HandIn();
        _vm.Undo();
    }

    private void Redo()
    {
        _inspectorPanel?.HandIn();
        _vm.Redo();
    }

    private void Print_Click(object sender, RoutedEventArgs e) => _vm.Print();

    private void ViewModel_SystemPrintRequested(object? sender, DocumentTab tab)
    {
        if (!tab.CanDraw)
        {
            _vm.ShowProblem(new Problem(Loc.T("Not printed"), Loc.T("Windows cannot draw the pages of {0}, so it would come out blank. Install Lazy Print or print it from another program.", tab.Title)));
            return;
        }
        var dialog = new PrintDialog { UserPageRangeEnabled = true, MinPage = 1, MaxPage = (uint)tab.PageCount };
        if (dialog.ShowDialog() != true) return;
        List<int>? pages = null;
        if (dialog.PageRangeSelection == PageRangeSelection.UserPages)
        {
            int from = Math.Clamp(dialog.PageRange.PageFrom, 1, tab.PageCount), to = Math.Clamp(dialog.PageRange.PageTo, 1, tab.PageCount);
            pages = [.. Enumerable.Range(from - 1, Math.Max(0, to - from + 1))];
        }
        var paginator = new PagePaginator(tab.Renderer, tab.PageCount, pages)
        {
            PageSize = new Size(dialog.PrintableAreaWidth, dialog.PrintableAreaHeight),
        };
        try
        {
            dialog.PrintDocument(paginator, tab.Title);
            if (paginator.Blank > 0) _vm.ShowProblem(new Problem(Loc.T("Not printed"), Loc.T("Some pages of {0} could not be drawn and came out blank.", tab.Title)));
            else _vm.SetStatus(Loc.T("Sent {0} to the printer.", tab.Title));
        }
        catch (System.Printing.PrintQueueException)
        {
            _vm.ShowProblem(new Problem(Loc.T("Not printed"), Loc.T("The printer did not take {0}. Check that it is on and has no error, then try again.", tab.Title)));
        }
    }

    // Combine and a view that holds the stage take dropped files into their own lists, so over them they do not open as tabs.
    private bool OverFileTarget(DragEventArgs e)
    {
        UIElement? target = _vm.HeldStage ?? (InspectorHost.Content is UIElement { AllowDrop: true } panel ? panel : null);
        if (target is null) return false;
        for (var node = e.OriginalSource as DependencyObject; node is not null;
             node = node is System.Windows.Media.Visual ? System.Windows.Media.VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node))
        {
            if (ReferenceEquals(node, target)) return true;
        }
        return false;
    }

    private void Window_PreviewDragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        if (OverFileTarget(e))
        {
            DropOverlay.Visibility = Visibility.Collapsed;
            return;
        }
        e.Effects = DragDropEffects.Copy;
        DropOverlay.Visibility = Visibility.Visible;
        e.Handled = true;
    }

    private void Window_PreviewDragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    private void Window_PreviewDrop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths || OverFileTarget(e)) return;
        e.Handled = true;
        _ = _vm.OpenFilesAsync(paths);
    }
}
