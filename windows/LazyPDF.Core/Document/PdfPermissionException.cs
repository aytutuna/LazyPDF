namespace LazyPDF.Core;

/// <summary>The file restricts itself and was not opened with the rights to change it this way.</summary>
public sealed class PdfPermissionException : UnauthorizedAccessException
{
    public PdfPermissionException(string message) : base(message) { }
}
