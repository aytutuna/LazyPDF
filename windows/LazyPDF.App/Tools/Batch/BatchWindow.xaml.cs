using System.Windows;
using System.Windows.Automation;
using LazyPDF.App.Documents;

namespace LazyPDF.App.Tools.Batch;

/// <summary>Runs a batch from the Home tab, where no document is open for the panel to sit beside. It says what happened in the window itself.</summary>
public partial class BatchWindow : Window, IToolHost
{
    // One for each window, over that window's tabs.
    private static readonly Dictionary<AppViewModel, BatchWindow> Opened = [];

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
        if (Opened.TryGetValue(vm, out var open))
        {
            open.Activate();
            return;
        }
        var window = new BatchWindow(vm) { Owner = owner };
        Opened[vm] = window;
        window.Show();
    }

    /// <summary>True while a batch started from this view model's window is running.</summary>
    internal static bool IsRunning(AppViewModel vm) => Opened.TryGetValue(vm, out var open) && open._busy is not null;

    /// <summary>When this view model's batch window is open, runs <paramref name="then"/> once it has closed and returns true.</summary>
    internal static bool WhenClosed(AppViewModel vm, Action then)
    {
        if (!Opened.TryGetValue(vm, out var open)) return false;
        open.Closed += (_, _) => then();
        return true;
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
        Opened.Remove(_vm);
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

    public Window? DialogOwner => this;

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
