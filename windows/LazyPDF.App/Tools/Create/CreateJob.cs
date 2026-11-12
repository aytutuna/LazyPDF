using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Create;

public static class CreateJob
{
    public static async Task RunAsync(IToolHost host, IImageCodec codec, IFontSource fonts, CreateRequest request)
    {
        MadePdf? made = null;
        try
        {
            // The engine cannot be stopped part way, so a cancel stops the wait and the result is dropped.
            await host.RunBusyAsync(Loc.T("Creating"), async token =>
                made = request.Source == CreateSource.WebPage ? await PdfMaker.MakeWebPageAsync(request, token)
                    : await Task.Run(() => PdfMaker.Make(request, codec, fonts, token), token).WaitAsync(token));
        }
        catch (Exception e) when (e is WebViewMissingException or PdfReadException or ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(CreateProblems.Failed(e, request.Source));
            return;
        }
        if (made is null) return;

        if (!await host.OpenNewAsync(made.Bytes, request.Title)) return;
        if (request.Source == CreateSource.Word)
        {
            host.ShowNotice(Loc.T("Made without Office"), WordNotice.Text(made));
            return;
        }
        if (made.Unreadable + made.Skipped == 0) return;
        var lines = new List<string>();
        if (made.Unreadable > 0)
            lines.Add(request.Source == CreateSource.Pictures
                ? Loc.Plural(made.Unreadable, "{0} picture could not be read.", "{0} pictures could not be read.")
                : Loc.T("Some letters have no shape in the font and were left out."));
        if (made.Skipped > 0)
            lines.Add(Loc.Plural(made.Skipped, "{0} picture was too large and was left out.", "{0} pictures were too large and were left out."));
        host.ShowNotice(Loc.T("Some left out"), string.Join(" ", lines));
    }
}
