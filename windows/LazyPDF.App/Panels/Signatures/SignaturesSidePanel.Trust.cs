// Trust settings: whether the roots Windows trusts count, and the certificates the user added by hand.
// Every change is saved at once and the signatures are checked again.

using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Windows;
using LazyPDF.App.Tools.Certificates;
using Microsoft.Win32;

namespace LazyPDF.App.Panels.Signatures;

/// <summary>A certificate the user trusts, as the list shows it.</summary>
/// <param name="Der">The certificate in base64, as <see cref="SigningSettings.TrustedCertificates"/> keeps it.</param>
public sealed record TrustRow(string Der, string Name, string Detail);

public partial class SignaturesSidePanel
{
    private void ShowTrust()
    {
        var settings = SigningSettingsStore.Load();
        WindowsTrust.IsChecked = settings.TrustWindowsStore;
        TrustList.ItemsSource = settings.TrustedCertificates.Select(Describe).ToList();
        bool none = settings.TrustedCertificates.Count == 0;
        TrustList.Visibility = none ? Visibility.Collapsed : Visibility.Visible;
        NoTrusted.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
    }

    private static TrustRow Describe(string der)
    {
        try
        {
            using var certificate = X509CertificateLoader.LoadCertificate(Convert.FromBase64String(der));
            string name = certificate.GetNameInfo(X509NameType.SimpleName, false);
            return new TrustRow(der, name.Length > 0 ? name : certificate.Subject, Loc.T("Expires {0}", certificate.NotAfter.ToShortDateString()));
        }
        catch (Exception e) when (e is FormatException or CryptographicException)
        {
            return new TrustRow(der, Loc.T("Unreadable certificate"), "");
        }
    }

    private void WindowsTrust_Click(object sender, RoutedEventArgs e)
    {
        SigningSettingsStore.Update(s => s.TrustWindowsStore = WindowsTrust.IsChecked == true);
        _ = BuildAsync();
    }

    private void AddTrust_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = Loc.T("Choose a certificate"), Filter = Loc.T("Certificate files") + "|*.cer;*.crt;*.pem;*.der" };
        if (dialog.ShowDialog() != true) return;
        string der;
        try
        {
            using var certificate = X509CertificateLoader.LoadCertificate(File.ReadAllBytes(dialog.FileName));
            der = Convert.ToBase64String(certificate.RawData);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            TellTrust(Loc.T("That file is not a certificate. Choose a .cer or .crt file."));
            return;
        }
        SigningSettingsStore.Update(s =>
        {
            if (!s.TrustedCertificates.Contains(der)) s.TrustedCertificates.Add(der);
        });
        TrustNote.Visibility = Visibility.Collapsed;
        ShowTrust();
        _ = BuildAsync();
    }

    private void RemoveTrust_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not TrustRow row) return;
        SigningSettingsStore.Update(s => s.TrustedCertificates.Remove(row.Der));
        ShowTrust();
        _ = BuildAsync();
    }

    private void TellTrust(string text)
    {
        TrustNote.Text = text;
        TrustNote.Visibility = Visibility.Visible;
    }
}
