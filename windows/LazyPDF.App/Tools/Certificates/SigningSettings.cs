using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Certificates;

/// <summary>What the user decided about signing and trust, kept between runs.</summary>
public sealed class SigningSettings
{
    /// <summary>Roots that Windows trusts count as trusted here too.</summary>
    public bool TrustWindowsStore { get; set; } = true;

    /// <summary>Certificates the user added by hand, DER bytes in base64.</summary>
    public List<string> TrustedCertificates { get; set; } = [];

    public const string SuggestedTimestampUrl = "http://timestamp.digicert.com";

    /// <summary>The last time stamp server used; a file that never had one suggests DigiCert's.</summary>
    public string TimestampUrl { get; set; } = SuggestedTimestampUrl;

    /// <summary>The options the verifier gets for a file; certificates that no longer parse are left out.</summary>
    public VerifyOptions Verify(string? password, X509Certificate2? certificate, DateTimeOffset now) => new()
    {
        UseSystemStore = TrustWindowsStore,
        TrustAnchors = [.. TrustedCertificates.Select(Parse).OfType<X509Certificate2>()],
        Now = now,
        Password = password,
        Certificate = certificate,
    };

    private static X509Certificate2? Parse(string base64)
    {
        try
        {
            return X509CertificateLoader.LoadCertificate(Convert.FromBase64String(base64));
        }
        catch (Exception e) when (e is FormatException or System.Security.Cryptography.CryptographicException)
        {
            return null;
        }
    }
}

/// <summary>signing.json in %APPDATA%\Lazy PDF, read and written like the preferences.</summary>
public static class SigningSettingsStore
{
    private static string Path(string directory) => System.IO.Path.Combine(directory, "signing.json");

    public static SigningSettings Load() => Load(StoreFiles.DefaultDirectory);

    /// <summary>Re-reads the file, applies <paramref name="change"/> and saves, so the panels that share it do not undo each other.</summary>
    public static void Update(Action<SigningSettings> change) => Update(change, StoreFiles.DefaultDirectory);

    internal static SigningSettings Load(string directory) =>
        StoreFiles.Load<SigningSettings>(Path(directory)) ?? new SigningSettings();

    internal static void Update(Action<SigningSettings> change, string directory)
    {
        var settings = Load(directory);
        change(settings);
        StoreFiles.Write(settings, Path(directory));
    }
}
