using System.Text.RegularExpressions;
using System.Windows;
using LazyPDF.App.Tools.Accessibility;

namespace LazyPDF.App.Viewer;

// Read aloud: the selection, or the pages from the one in view, said one piece at a time.
public partial class PageViewer
{
    private CancellationTokenSource? _speech;

    // Replaced by the tests, which have no audio.
    internal Func<string, CancellationToken, Task>? Say;

    internal bool Speaking => _speech is not null;

    private void ReadAloud_Click(object sender, RoutedEventArgs e) => ToggleReadAloud();

    internal void ToggleReadAloud()
    {
        if (_speech is not null) StopSpeech();
        else if (_tab is not null) _ = ReadAloudAsync();
    }

    private void StopSpeech()
    {
        _speech?.Cancel();
        _speech = null;
    }

    internal static List<string> Pieces(string text) =>
        Regex.Split(text, @"\r?\n[ \t]*\r?\n")
            .Select(piece => piece.Replace("\r", "").Replace('\n', ' ').Trim())
            .Where(piece => piece.Length > 0)
            .ToList();

    private async Task ReadAloudAsync()
    {
        using var source = new CancellationTokenSource();
        var cancel = source.Token;
        _speech = source;
        Speaker? speaker = null;
        try
        {
            var say = Say;
            if (say is null)
            {
                speaker = new Speaker();
                say = speaker.SayAsync;
            }
            var runs = await GetSelectionAsync();
            cancel.ThrowIfCancellationRequested();
            if (runs.Count > 0)
            {
                foreach (var line in string.Join('\n', runs.Select(run => run.Text)).Split('\n'))
                {
                    if (line.Trim() is { Length: > 0 } piece) await say(piece, cancel);
                }
                return;
            }
            bool any = false;
            for (int page = Surface.CurrentPage; page < Surface.PageCount; page++)
            {
                var text = await GetTextAsync(page);
                cancel.ThrowIfCancellationRequested();
                var pieces = text is null ? [] : Pieces(text.Text);
                if (pieces.Count == 0) continue;
                any = true;
                Surface.GoToPage(page);
                foreach (var piece in pieces) await say(piece, cancel);
            }
            if (!any) ShowToast(Loc.T("This file has no text to read. Try Make searchable."));
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
            // No voice, no media components or a device that went away; nothing above an async void caller would catch it.
            ShowToast(Loc.T("Windows has no voice to read with."));
        }
        finally
        {
            speaker?.Dispose();
            if (ReferenceEquals(_speech, source)) _speech = null;
        }
    }
}
