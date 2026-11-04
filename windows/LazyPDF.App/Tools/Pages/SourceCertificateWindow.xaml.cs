using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Services;

namespace LazyPDF.App.Tools.Pages;

/// <summary>Asks which certificate opens a file a tool is about to read pages from.</summary>
internal sealed partial class SourceCertificateWindow : Window
{
    private sealed record Item(CertificateChoice Choice)
    {
        public override string ToString() => $"{Choice.Name} · {Choice.Issuer} · {Choice.Expires:d}";
    }

    private SourceCertificateWindow(string name, bool wrong)
    {
        InitializeComponent();
        Title = Loc.T("Choose a certificate");
        Message.Text = Loc.T("{0} is encrypted for the holders of certain certificates. Pick the certificate that can open it.", name);
        var choices = Read();
        Choices.ItemsSource = choices.Select(c => new Item(c)).ToList();
        if (wrong || choices.Count == 0)
        {
            Problem.Text = choices.Count == 0 ? Loc.T("No certificate with a private key was found on this computer.") : Loc.T("That certificate does not open this file.");
            Problem.Visibility = Visibility.Visible;
        }
        Loaded += (_, _) => Choices.Focus();
    }

    private static IReadOnlyList<CertificateChoice> Read()
    {
        try
        {
            return WindowsCertificates.WithPrivateKey();
        }
        catch (CryptographicException)
        {
            return [];
        }
    }

    public static X509Certificate2? Ask(string name, bool wrong)
    {
        var window = new SourceCertificateWindow(name, wrong) { Owner = Application.Current?.MainWindow };
        return window.ShowDialog() == true && window.Choices.SelectedItem is Item item ? item.Choice.Certificate : null;
    }

    private void Choices_SelectionChanged(object sender, SelectionChangedEventArgs e) => OpenButton.IsEnabled = Choices.SelectedItem is not null;

    private void Open_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
