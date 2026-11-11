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

    private void OpenWithDialog(Action? then = null)
    {
        var dialog = new OpenFileDialog
        {
            Multiselect = true,
            Filter = FileKinds.OpenFilter(Loc.T("PDF files"), Loc.T("Pictures"), Loc.T("Text files"), Loc.T("All supported files")),
        };
        if (dialog.ShowDialog(this) != true) return;
        _ = OpenThenAsync(dialog.FileNames, then);
    }

    private async Task OpenThenAsync(string[] paths, Action? then)
    {
        await _vm.OpenFilesAsync(paths);
        if (then is not null && _vm.ActiveDocument is not null) then();
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

    private async void ViewModel_SystemPrintRequested(object? sender, DocumentTab tab)
    {
        if (!tab.CanDraw)
        {
            _vm.ShowProblem(new Problem(Loc.T("Not printed"), Loc.T("Windows cannot draw the pages of {0}, so it would come out blank. Install Lazy Print or print it from another program.", tab.Title)));
            return;
        }
        var dialog = new PrintDialog { UserPageRangeEnabled = true, CurrentPageEnabled = true, MinPage = 1, MaxPage = (uint)tab.PageCount };
        if (dialog.ShowDialog() != true) return;
        var pages = PagePaginator.PagesFor(dialog.PageRangeSelection, dialog.PageRange.PageFrom, dialog.PageRange.PageTo, tab.PageIndex, tab.PageCount);
        if (pages is { Count: 0 }) return;
        var queue = dialog.PrintQueue;
        var ticket = dialog.PrintTicket;
        var size = new Size(dialog.PrintableAreaWidth, dialog.PrintableAreaHeight);
        PagePaginator? paginator = null;
        var written = false;
        try
        {
            await _vm.RunBusyAsync(Loc.T("Printing {0}…", tab.Title), token =>
            {
                var shown = Environment.TickCount64;
                paginator = new PagePaginator(tab.Renderer, tab.PageCount, pages, token, (n, count) =>
                {
                    var now = Environment.TickCount64;
                    if (now - shown < 100 && n < count) return;
                    shown = now;
                    Dispatcher.BeginInvoke(() => _vm.SetBusyText(Loc.T("Printing page {0} of {1}", n, count)), System.Windows.Threading.DispatcherPriority.Background);
                })
                {
                    PageSize = size,
                };
                var done = new TaskCompletionSource();
                var thread = new Thread(() =>
                {
                    try
                    {
                        queue.CurrentJobSettings.Description = tab.Title;
                        System.Printing.PrintQueue.CreateXpsDocumentWriter(queue).Write(paginator, ticket);
                        written = true;
                        done.SetResult();
                    }
                    catch (Exception ex)
                    {
                        done.SetException(ex);
                    }
                });
                thread.SetApartmentState(ApartmentState.STA);
                thread.IsBackground = true;
                thread.Start();
                return done.Task;
            });
            if (!written) return;
            if (paginator!.Blank > 0) _vm.ShowProblem(new Problem(Loc.T("Not printed"), Loc.T("Some pages of {0} could not be drawn and came out blank.", tab.Title)));
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
        UIElement? target = _vm.HeldStage ?? (InspectorHost.Content is UIElement panel && panel.ReadLocalValue(UIElement.AllowDropProperty) is true ? panel : null);
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
        OpenOrHold(paths);
    }

    private void OpenOrHold(IEnumerable<string> paths)
    {
        if (Modal || _vm.IsBusy || _actionRunning)
        {
            // A file arriving means the person is still working, and held files would be lost on exit.
            if (_vm.IsExiting) _vm.CancelClose();
            if (_held.Count == 0) _heldMessage = _vm.Message;
            _held.AddRange(paths);
            _vm.SetStatus(Loc.T("Will open when you are done here."));
            return;
        }
        var all = _held.Concat(paths).ToList();
        _held.Clear();
        _ = _vm.OpenFilesAsync(all);
    }

    // Opening held files replaces the message on the info bar, so they wait for a message that came after the hold
    // until it is dismissed or replaced by another.
    internal static bool MayRelease(InfoMessage? showing, InfoMessage? atHold, InfoMessage? atEnd) =>
        showing is null || ReferenceEquals(showing, atHold) || atEnd is not null && !ReferenceEquals(showing, atEnd);

    private void ReleaseHeld()
    {
        if (Modal || _vm.IsBusy || _actionRunning)
        {
            _settledMessage = null;
            return;
        }
        if (_held.Count == 0) return;
        if (!MayRelease(_vm.Message, _heldMessage, _settledMessage))
        {
            _settledMessage ??= _vm.Message;
            return;
        }
        var paths = _held.ToList();
        _held.Clear();
        _ = _vm.OpenFilesAsync(paths);
    }
}
