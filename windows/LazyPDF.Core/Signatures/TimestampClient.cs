using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;

namespace LazyPDF.Core;

internal static class TimestampClient
{
    /// <summary>
    /// Asks the server for an RFC 3161 token over <paramref name="value"/> (or over itself when it already is the hash)
    /// and returns the token encoded. The token's own signature is checked when a file is verified, not here.
    /// </summary>
    public static byte[] Request(TimestampSettings settings, string url, byte[] value, bool hashed = false)
    {
        byte[] nonce = RandomNumberGenerator.GetBytes(8);
        nonce[0] &= 0x7F;
        var request = hashed
            ? Rfc3161TimestampRequest.CreateFromHash(value, settings.Digest, nonce: nonce, requestSignerCertificates: true)
            : Rfc3161TimestampRequest.CreateFromData(value, settings.Digest, nonce: nonce, requestSignerCertificates: true);
        byte[]? response = settings.Transport.Post(url, "application/timestamp-query", request.Encode());
        if (response is null) throw new InvalidOperationException(SignatureText.NoTimestamp);
        try
        {
            return request.ProcessResponse(response, out _).AsSignedCms().Encode();
        }
        catch (CryptographicException)
        {
            throw new InvalidOperationException(SignatureText.NoTimestamp);
        }
    }
}
