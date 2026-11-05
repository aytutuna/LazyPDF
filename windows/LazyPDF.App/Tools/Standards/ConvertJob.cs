using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Standards;

/// <summary>The conversion of a tab's file, taken from the tab on the UI thread and run off it.</summary>
internal sealed class ConvertJob
{
    private readonly ReadOnlyMemory<byte> _bytes;
    private readonly string? _password;
    private readonly bool _certificate;
    private readonly Func<PdfDocument> _open;

    public ConvertJob(DocumentTab tab)
    {
        _bytes = tab.Session.Current;
        _password = tab.Password;
        _certificate = tab.Certificate is not null;
        _open = OpenCopy.Of(tab);
    }

    public PdfAConversion Run(PdfALevel level, IFontSource fonts)
    {
        try
        {
            string? password = _password;
            byte[] bytes = _bytes.ToArray();
            if (_certificate)
            {
                // The converter takes a password and nothing else, so a file opened with a certificate is handed over unencrypted.
                using var document = _open();
                bytes = document.SaveRewrite();
                password = null;
            }
            return new PdfAConverter(fonts).Convert(bytes, level, DateTimeOffset.Now, password);
        }
        catch (UnauthorizedAccessException)
        {
            // Dropping the encryption needs the owner's rights, which the converter's own check of the permissions does not cover.
            return new PdfAConversion(null, PdfAText.NoRights, [], []);
        }
        catch (PdfReadException error)
        {
            return new PdfAConversion(null, PdfAText.CouldNotRewrite(error.Message), [], []);
        }
    }
}
