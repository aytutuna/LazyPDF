namespace LazyPDF.Core;

/// <summary>
/// How <see cref="PdfDocument.SaveRewrite"/> writes. <paramref name="UseObjectStreams"/> packs the
/// plain objects into object streams and lists them in a cross-reference stream (PDF 1.5).
/// <paramref name="Security"/> encrypts the new file with that handler; null leaves it open, so
/// passing null for an encrypted file removes the encryption, and passing the document's own
/// <see cref="PdfDocument.Security"/> keeps it. <paramref name="DocumentId"/> is the first string
/// of the new /ID (16 random bytes when null); a handler made by <see cref="PdfSecurity.Create"/>
/// for the 128-bit strength must have been given the same one.
/// </summary>
public sealed record PdfSaveOptions(bool UseObjectStreams = false, PdfSecurity? Security = null, byte[]? DocumentId = null);
