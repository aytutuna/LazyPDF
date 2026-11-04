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
        if (_vm.ActiveDocument is not { } tab) return;
        if (AppViewModel.NeedsName(tab)) SaveAsWithDialog();
        else _vm.Save(tab);
    }

    private void SaveAs_Click(object sender, RoutedEventArgs e) => SaveAsWithDialog();

    private bool SaveAsWithDialog()
    {
        if (_vm.ActiveDocument is not { } tab || AskForPath(tab, Loc.T("Save as")) is not { } path) return false;
        return _vm.SaveAs(tab, path);
    }

    private void SaveCompact_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.ActiveDocument is not { } tab) return;
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

    private void Undo_Click(object sender, RoutedEventArgs e) => _vm.Undo();

    private void Redo_Click(object sender, RoutedEventArgs e) => _vm.Redo();

    private void Print_Click(object sender, RoutedEventArgs e) => _vm.Print();

    private void ViewModel_SystemPrintRequested(object? sender, DocumentTab tab)
    {
        if (!tab.CanDraw)
        {
            _vm.ShowProblem(new Problem(Loc.T("Not printed"), Loc.T("Windows cannot draw the pages of {0}, so it would come out blank. Install Lazy Print or print it from another program.", tab.Title)));
            return;
        }
        var dialog = new PrintDialog { UserPageRangeEnabled = false };
        if (dialog.ShowDialog() != true) return;
        var paginator = new PagePaginator(tab.Renderer, tab.PageCount)
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

    private void Window_PreviewDragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Effects = DragDropEffects.Copy;
        DropOverlay.Visibility = Visibility.Visible;
        e.Handled = true;
    }

    private void Window_PreviewDragLeave(object sender, DragEventArgs e) => DropOverlay.Visibility = Visibility.Collapsed;

    private void Window_PreviewDrop(object sender, DragEventArgs e)
    {
        DropOverlay.Visibility = Visibility.Collapsed;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        e.Handled = true;
        _ = _vm.OpenFilesAsync(paths);
    }
}
