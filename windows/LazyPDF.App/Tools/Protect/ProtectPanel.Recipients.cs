// The certificates a file is locked for: picked from the Windows store or read from a file.

using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using LazyPDF.App.Documents;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Protect;

public partial class ProtectPanel
{
    private void AddStore_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = AddStoreButton, Placement = PlacementMode.Bottom, MaxHeight = 320 };
        var found = RecipientSource.FromStore().Where(r => !_recipients.Any(have => have.Certificate.Thumbprint == r.Certificate.Thumbprint)).ToList();
        foreach (var recipient in found)
        {
            var item = new MenuItem { Header = recipient.Name, ToolTip = recipient.Details };
            AutomationProperties.SetName(item, recipient.Name);
            item.Click += (_, _) => Add(recipient);
            menu.Items.Add(item);
        }
        if (found.Count == 0) menu.Items.Add(new MenuItem { Header = Loc.T("No certificates found."), IsEnabled = false });
        menu.IsOpen = true;
    }

    private void AddFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = Loc.T("Certificates"),
            Filter = Loc.T("Certificates") + "|*.cer;*.crt;*.der;*.pem|" + Loc.T("All files") + "|*.*",
            Multiselect = true,
        };
        if (dialog.ShowDialog() != true) return;
        foreach (string path in dialog.FileNames)
        {
            if (RecipientSource.FromFile(path) is { } recipient) Add(recipient);
            else Host?.ShowProblem(new Problem(Loc.T("Not a usable certificate"), Loc.T("{0} is not an RSA certificate. Ask for the person's certificate file.", System.IO.Path.GetFileName(path))));
        }
    }

    private void Add(Recipient recipient)
    {
        if (_recipients.Any(r => r.Certificate.Thumbprint == recipient.Certificate.Thumbprint)) return;
        _recipients.Add(recipient);
        ShowRecipients();
        UpdateState();
    }

    private void RemoveRecipient_Click(object sender, RoutedEventArgs e)
    {
        if (RecipientList.SelectedItem is not Recipient picked) return;
        _recipients.Remove(picked);
        ShowRecipients();
        UpdateState();
    }

    private void RecipientList_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        RemoveRecipientButton.IsEnabled = RecipientList.SelectedItem is not null;

    private void ShowRecipients()
    {
        RecipientList.ItemsSource = null;
        RecipientList.ItemsSource = _recipients.ToList();
        RecipientList.Visibility = _recipients.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }
}
