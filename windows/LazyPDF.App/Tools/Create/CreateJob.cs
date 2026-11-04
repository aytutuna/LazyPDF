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
                made = await Task.Run(() => PdfMaker.Make(request, codec, fonts, token), token).WaitAsync(token));
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(CreateProblems.Failed(e, request.Source));
            return;
        }
        if (made is null) return;

        await host.OpenNewAsync(made.Bytes, request.Title);
        if (made.Unreadable == 0) return;
        host.ShowNotice(Loc.T("Some left out"), request.Source == CreateSource.Pictures
            ? Loc.Plural(made.Unreadable, "{0} picture could not be read.", "{0} pictures could not be read.")
            : Loc.T("Some letters have no shape in the font and were left out."));
    }
}
