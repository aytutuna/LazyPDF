using System.Runtime.InteropServices;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;

namespace LazyPDF.App.Tools.Accessibility;

/// <summary>Says text with the voice Windows has chosen, one piece at a time.</summary>
internal sealed class Speaker : IDisposable
{
    private readonly SpeechSynthesizer _voice = new();
    private readonly MediaPlayer _player = new();

    /// <summary>Returns when the text has been said, or throws when <paramref name="cancel"/> stops it.</summary>
    public async Task SayAsync(string text, CancellationToken cancel)
    {
        using var stream = await _voice.SynthesizeTextToStreamAsync(text);
        using var source = MediaSource.CreateFromStream(stream, stream.ContentType);
        var done = new TaskCompletionSource();
        void Ended(MediaPlayer player, object args) => done.TrySetResult();
        void Failed(MediaPlayer player, MediaPlayerFailedEventArgs args) => done.TrySetException(new COMException(args.ErrorMessage, (int)args.ExtendedErrorCode.HResult));
        _player.MediaEnded += Ended;
        _player.MediaFailed += Failed;
        try
        {
            _player.Source = source;
            _player.Play();
            using (cancel.Register(() => done.TrySetCanceled(cancel)))
            {
                await done.Task;
            }
        }
        finally
        {
            _player.Pause();
            _player.MediaEnded -= Ended;
            _player.MediaFailed -= Failed;
            _player.Source = null;
        }
    }

    public void Dispose()
    {
        _player.Dispose();
        _voice.Dispose();
    }
}
