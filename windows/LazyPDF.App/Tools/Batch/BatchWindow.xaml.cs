using System.Windows;
using System.Windows.Automation;
using LazyPDF.App.Documents;

namespace LazyPDF.App.Tools.Batch;

/// <summary>Runs a batch from the Home tab, where no document is open for the panel to sit beside. It says what happened in the window itself.</summary>
public partial class BatchWindow : Window, IToolHost
{
    private static BatchWindow? _open;

    private readonly AppViewModel _vm;
    private CancellationTokenSource? _busy;

    private BatchWindow(AppViewModel vm)
    {
        _vm = vm;
        InitializeComponent();
        Panel.AttachHost(this);
        Panel.ActionChanged += (_, _) => RefreshRun();
        RunButton.Content = Panel.Action!.Text;
        AutomationProperties.SetName(RunButton, Panel.Action.Text);
        RefreshRun();
    }

    /// <summary>Opens the window, or brings forward the one that is open.</summary>
    public static void Open(Window owner, AppViewModel vm)
    {
        if (_open is { } open)
        {
            open.Activate();
            return;
        }
        _open = new BatchWindow(vm) { Owner = owner };
        _open.Show();
    }

    private void RefreshRun() => RunButton.IsEnabled = _busy is null && Panel.Action!.CanRun();

    private async void RunButton_Click(object sender, RoutedEventArgs e) => await Panel.Action!.Run();

    private void CancelButton_Click(object sender, RoutedEventArgs e) => _busy?.Cancel();

    // The window is not a dialog, so IsCancel alone neither closes it nor answers Esc.
    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _busy?.Cancel();
        Panel.StopWatching();
        Panel.ClearPassword();
        _open = null;
    }

    public async Task RunBusyAsync(string text, Func<CancellationToken, Task> work)
    {
        using var source = new CancellationTokenSource();
        _busy = source;
        HideMessage();
        BusyBar.Visibility = CancelButton.Visibility = Visibility.Visible;
        RefreshRun();
        try
        {
            await work(source.Token);
        }
        catch (OperationCanceledException)
        {
            SetStatus(Loc.T("Canceled."));
        }
        finally
        {
            _busy = null;
            BusyBar.Visibility = CancelButton.Visibility = Visibility.Collapsed;
            RefreshRun();
        }
    }

    public void ShowProblem(Problem problem) => ShowMessage(problem.Title, problem.Text);

    public void ShowNotice(string title, string text, NoticeAction? action = null) => ShowMessage(title, text);

    public void SetStatus(string sentence) => StatusText.Text = sentence;

    public Task OpenAsync(string path) => _vm.OpenAsync(path);

    public Task<bool> OpenNewAsync(byte[] pdf, string title) => _vm.OpenNewAsync(pdf, title);

    public Task ReloadAsync(DocumentTab tab) => _vm.ReloadAsync(tab);

    private void ShowMessage(string title, string text)
    {
        MessageTitle.Text = title;
        MessageText.Text = text;
        MessageTitle.Visibility = MessageText.Visibility = Visibility.Visible;
    }

    private void HideMessage() => MessageTitle.Visibility = MessageText.Visibility = Visibility.Collapsed;
}
