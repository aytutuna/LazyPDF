using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

// Strings are decrypted as their object loads (ISO 32000-1 7.6.2), except in object streams, which
// are encrypted as a whole, and in the /Encrypt dictionary itself.
public sealed partial class PdfDocument
{
    private X509Certificate2? _certificate;
    private PdfSecurity? _security;
    private PdfDictionary? _encrypt;
    private int _encryptNumber;
    private byte[] _securityId = [];

    /// <summary>Opens the /Encrypt dictionary with the password. Everything loaded before it was read without the key, so it is dropped.</summary>
    private void OpenSecurity()
    {
        _security = null;
        _encrypt = null;
        _encryptNumber = 0;
        var entry = Trailer["Encrypt"];
        if (entry is null or PdfNull) return;
        if (entry is PdfReference reference) _encryptNumber = reference.Number;
        _encrypt = Flatten(entry, 3) as PdfDictionary ?? throw PdfReadException.Damaged("The /Encrypt entry is not a dictionary.");
        _securityId = Id.FirstOrDefault() ?? [];
        bool publicKey = _encrypt["Filter"] is PdfName { Value: "Adobe.PubSec" };
        _security = publicKey
            ? _certificate is null ? null : PdfSecurity.OpenPublicKey(_encrypt, _certificate)
            : PdfSecurity.Open(_encrypt, _securityId, _password);
        if (_security is null)
        {
            throw publicKey
                ? new PdfReadException(PdfReadProblem.CertificateRequired, "The file is encrypted for recipients and the certificate does not open it.")
                : new PdfReadException(PdfReadProblem.PasswordRequired, "The file is encrypted and the password does not open it.");
        }
        _objects.Clear();
        _objectStreams.Clear();
    }

    /// <summary>
    /// Changing or removing the encryption of an open file is for whoever holds the owner's rights:
    /// the owner password for the standard handler, a recipient with bit 2 for the public-key one.
    /// A reader without them may still do it when the file restricts nothing, since there is then
    /// nothing to protect. Keeping the file's own handler is always allowed, and so is encrypting
    /// a file that has none.
    /// </summary>
    internal void RequireEncryptionRights(PdfSecurity? target)
    {
        if (_security is { OpenedAsOwner: false, Permissions: not PdfPermissions.All } && !ReferenceEquals(target, _security))
            throw new PdfPermissionException("The file restricts its permissions and was not opened with the rights to change its encryption.");
    }

    /// <summary>
    /// The first /ID string a save has to keep: the older handlers make the file key from it, so it
    /// is the one the key was made with (an indirect /ID reads garbled once the file is decrypted).
    /// Null when an unencrypted file has none.
    /// </summary>
    internal byte[]? FirstId => _security is null ? Id.FirstOrDefault() : _securityId;

    private void DecryptStrings(PdfObject value, int number, int generation)
    {
        switch (value)
        {
            case PdfString text:
                text.Bytes = _security!.DecryptString(number, generation, text.Bytes);
                break;
            case PdfArray array:
                foreach (var item in array.Items) DecryptStrings(item, number, generation);
                break;
            case PdfStream stream:
                DecryptStrings(stream.Dictionary, number, generation);
                break;
            case PdfDictionary dictionary:
                // A signature's contents are the signature, not text (7.6.1).
                bool signature = IsSignature(dictionary);
                foreach (var (key, item) in dictionary.Entries)
                {
                    if (!(signature && key == "Contents")) DecryptStrings(item, number, generation);
                }
                break;
        }
    }

    internal static bool IsSignature(PdfDictionary dictionary) =>
        dictionary["Type"] is PdfName { Value: "Sig" or "DocTimeStamp" } || dictionary.ContainsKey("ByteRange");
}
