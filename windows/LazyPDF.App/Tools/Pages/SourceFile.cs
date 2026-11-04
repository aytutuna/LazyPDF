using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>Another PDF a tool takes pages from.</summary>
internal static class SourceFile
{
    /// <summary>
    /// Reads and opens the file off the UI thread, asking for its password or certificate when it has one; null, with the reason shown, when it cannot be used.
    /// <paramref name="askPassword"/> gets the file name and whether the last password was wrong, and returns null when the person gives up;
    /// <paramref name="askCertificate"/> does the same for a file locked to certificate holders.
    /// </summary>
    public static async Task<PdfDocument?> OpenAsync(IToolHost host, string path, Func<string, bool, string?>? askPassword = null,
                                                     Func<string, bool, X509Certificate2?>? askCertificate = null)
    {
        string name = System.IO.Path.GetFileName(path);
        string? password = null;
        X509Certificate2? certificate = null;
        while (true)
        {
            PdfDocument? document = null;
            try
            {
                await host.RunBusyAsync(Loc.T("Reading file"), token => Task.Run(async () =>
                {
                    byte[] bytes = await File.ReadAllBytesAsync(path, token);
                    document = certificate is null ? PdfDocument.Open(bytes, password) : PdfDocument.Open(bytes, certificate);
                }, token));
                return document;
            }
            catch (PdfReadException error) when (error.Problem == PdfReadProblem.PasswordRequired)
            {
                certificate = null;
                password = (askPassword ?? SourcePasswordWindow.Ask)(name, password is not null);
                if (password is null) return null;
            }
            catch (PdfReadException error) when (error.Problem == PdfReadProblem.CertificateRequired)
            {
                certificate = (askCertificate ?? SourceCertificateWindow.Ask)(name, certificate is not null);
                if (certificate is null) return null;
            }
            catch (Exception error) when (error is PdfReadException or IOException or UnauthorizedAccessException)
            {
                host.ShowProblem(Problems.Open(error, name));
                return null;
            }
        }
    }
}
