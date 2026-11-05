using System.Windows;
using System.Windows.Automation;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Standards;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

// The reading order as a list, and reading it out with the voice Windows has.
public partial class AccessibilityPanel
{
    private IReadOnlyList<string> _lines = [];
    private CancellationTokenSource? _reading;
    private int _readTicket;

    private async Task BuildReadAsync()
    {
        _readStale = false;
        int ticket = ++_readTicket;
        ReadNote.Text = Loc.T("Reading the tags");
        ReadAloud.IsEnabled = false;
        string order;
        try
        {
            var open = OpenCopy.Of(Tab!);
            order = await Task.Run(() =>
            {
                using var copy = open();
                return ReadingOrder.Export(copy);
            });
        }
        catch (Exception error) when (error is PdfReadException or InvalidOperationException)
        {
            order = "";
        }
        if (ticket != _readTicket) return;
        _lines = ReadingLines.Of(order);
        OrderList.ItemsSource = _lines;
        OrderList.Visibility = _lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ReadAloud.IsEnabled = _lines.Count > 0;
        ReadNote.Text = _lines.Count > 0
            ? Loc.T("{0} lines, in the order a screen reader reads them.", _lines.Count)
            : Loc.T("The file has no tags, so it has no reading order. Add tags first.");
    }

    private void StopReading() => _reading?.Cancel();

    private async void ReadAloud_Click(object sender, RoutedEventArgs e)
    {
        if (_reading is not null)
        {
            StopReading();
            return;
        }
        using var source = new CancellationTokenSource();
        _reading = source;
        SetReading(true);
        var host = Host;
        try
        {
            using var speaker = new Speaker();
            for (int i = Math.Max(OrderList.SelectedIndex, 0); i < _lines.Count; i++)
            {
                source.Token.ThrowIfCancellationRequested();
                OrderList.SelectedIndex = i;
                OrderList.ScrollIntoView(_lines[i]);
                string text = ReadingLines.Spoken(_lines[i]);
                if (text.Length > 0) await speaker.SayAsync(text, source.Token);
            }
            OrderList.SelectedIndex = -1;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
            // Speech can fail in many ways (no voice, no media components, a device that went away) and nothing above an async void handler would catch it.
            host?.ShowProblem(new Problem(Loc.T("Cannot read aloud"), Loc.T("Windows has no voice ready. Add one under Time and language, Speech.")));
        }
        finally
        {
            _reading = null;
            SetReading(false);
        }
    }

    private void SetReading(bool reading)
    {
        string text = reading ? Loc.T("Stop reading") : Loc.T("Read aloud");
        ReadAloud.Content = text;
        AutomationProperties.SetName(ReadAloud, text);
        Icon.SetGlyph(ReadAloud, reading ? "" : "");
    }
}
