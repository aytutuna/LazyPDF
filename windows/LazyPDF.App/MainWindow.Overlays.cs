// The overlays that sit on the window instead of opening one: the password or certificate of a locked file,
// what to do with unsaved changes, what a crash left, the settings and the About screen. While one is up the rest of the
// window is disabled, so the keyboard cannot reach behind it either.

using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;

namespace LazyPDF.App;

public partial class MainWindow
{
    private (string Name, bool Certificate, int Attempts)? _shownRequest;
    private DocumentTab? _shownQuestion;
    private bool _settingsOpen;
    private bool _aboutOpen;
    private bool _loadingSettings;
    private bool _wasModal;
    private bool _recoveryShown;
    private IInputElement? _focusBeforeOverlay;

    private bool Modal => PasswordOverlay.Visibility == Visibility.Visible || CloseOverlay.Visibility == Visibility.Visible
                          || RecoveryOverlay.Visibility == Visibility.Visible || _settingsOpen || _aboutOpen;

    private void RefreshOverlays()
    {
        var focused = Keyboard.FocusedElement;
        RefreshPasswordOverlay();
        RefreshCloseOverlay();
        RefreshRecoveryOverlay();
        SettingsOverlay.Visibility = _settingsOpen ? Visibility.Visible : Visibility.Collapsed;
        AboutOverlay.Visibility = _aboutOpen ? Visibility.Visible : Visibility.Collapsed;
        bool modal = Modal;
        if (modal && !_wasModal) _focusBeforeOverlay = focused;
        TabBar.IsEnabled = !modal && !_actionRunning && !_vm.IsBusy;
        ToolStrip.IsEnabled = !modal && !_vm.IsBusy;
        ContentAreaBehind.IsEnabled = !modal && !_vm.IsBusy;
        if (!modal && _wasModal) ReturnFocus();
        _wasModal = modal;
    }

    private void ReturnFocus()
    {
        var back = _focusBeforeOverlay;
        _focusBeforeOverlay = null;
        if (back is UIElement { IsVisible: true, IsEnabled: true } element) element.Focus();
    }

    private UIElement ContentAreaBehind => Home.Visibility == Visibility.Visible ? Home : Workspace;

    private void RefreshPasswordOverlay()
    {
        if (_vm.PasswordRequest is not { } request)
        {
            PasswordOverlay.Visibility = Visibility.Collapsed;
            _shownRequest = null;
            return;
        }
        var key = (request.Name, request.NeedsCertificate, request.Attempts);
        PasswordOverlay.Visibility = Visibility.Visible;
        PasswordProblem.Text = request.Problem ?? "";
        PasswordProblem.Visibility = request.Problem is null ? Visibility.Collapsed : Visibility.Visible;
        if (_shownRequest == key) return;
        _shownRequest = key;
        PasswordInput.Clear();
        PasswordInput.Visibility = request.NeedsCertificate ? Visibility.Collapsed : Visibility.Visible;
        CertificateList.Visibility = request.NeedsCertificate ? Visibility.Visible : Visibility.Collapsed;
        if (request.NeedsCertificate)
        {
            PasswordTitle.Text = Loc.T("Choose a certificate");
            PasswordText.Text = Loc.T("{0} is encrypted for the holders of certain certificates. Pick the certificate that can open it.", request.Name);
            CertificateList.ItemsSource = request.Certificates.Select(c => new CertificateItem(c)).ToList();
            if (request.Certificates.Count == 0)
            {
                PasswordProblem.Text = Loc.T("No certificate with a private key was found on this computer.");
                PasswordProblem.Visibility = Visibility.Visible;
            }
            PasswordOpen.IsEnabled = false;
            CertificateList.Focus();
        }
        else
        {
            PasswordTitle.Text = Loc.T("Password needed");
            PasswordText.Text = Loc.T("{0} is protected. Type its password to open it.", request.Name);
            PasswordOpen.IsEnabled = true;
            PasswordInput.Focus();
        }
        if (request.Problem is not null) Announce(PasswordProblem);
    }

    private sealed record CertificateItem(CertificateChoice Choice)
    {
        public override string ToString() => $"{Choice.Name} · {Choice.Issuer} · {Choice.Expires:d}";
    }

    private void CertificateList_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        PasswordOpen.IsEnabled = CertificateList.SelectedItem is not null;

    private void PasswordOpen_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.PasswordRequest is not { } request) return;
        if (request.NeedsCertificate)
        {
            if (CertificateList.SelectedItem is CertificateItem item) _ = _vm.SubmitCertificateAsync(item.Choice);
        }
        else
        {
            _ = _vm.SubmitPasswordAsync(PasswordInput.Password);
        }
    }

    private void PasswordCancel_Click(object sender, RoutedEventArgs e) => _vm.CancelPending();

    private void PasswordOverlay_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        _vm.CancelPending();
        e.Handled = true;
    }

    private void RefreshCloseOverlay()
    {
        if (_vm.CloseQuestion is not { } tab)
        {
            CloseOverlay.Visibility = Visibility.Collapsed;
            _shownQuestion = null;
            return;
        }
        CloseOverlay.Visibility = Visibility.Visible;
        bool marksOnly = !tab.IsDirty;
        CloseTitle.Text = marksOnly ? Loc.T("Close {0}?", tab.Title) : Loc.T("Save changes to {0}?", tab.Title);
        string lost = Loc.T("Your changes are lost if you do not save them.");
        string marks = Loc.Plural(tab.PendingMarks, "{0} redaction mark is not applied yet.", "{0} redaction marks are not applied yet.");
        CloseBody.Text = marksOnly ? marks : tab.PendingMarks > 0 ? $"{lost} {marks}" : lost;
        CloseSaveButton.Visibility = marksOnly ? Visibility.Collapsed : Visibility.Visible;
        string discard = marksOnly ? Loc.T("Close") : Loc.T("Don't save");
        CloseDiscardButton.Content = discard;
        AutomationProperties.SetName(CloseDiscardButton, discard);
        if (!ReferenceEquals(_shownQuestion, tab)) (marksOnly ? CloseCancelButton : CloseSaveButton).Focus();
        _shownQuestion = tab;
    }

    private void CloseSave_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.CloseQuestion is not { } tab) return;
        bool saved;
        if (AppViewModel.NeedsName(tab))
        {
            _vm.ActiveTab = tab;
            saved = SaveAsWithDialog();
        }
        else
        {
            saved = _vm.Save(tab, closeAfter: true);
            if (!saved && _vm.Message is { IsError: true }) saved = SaveAsWithDialog();
        }
        if (saved) _vm.Close(tab);
        else if (_vm.Message is { Action: not null }) _vm.CancelClose();
    }

    private void CloseDiscard_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.CloseQuestion is { } tab) _vm.Close(tab);
    }

    private void CloseCancel_Click(object sender, RoutedEventArgs e) => _vm.CancelClose();

    private void CloseOverlay_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        _vm.CancelClose();
        e.Handled = true;
    }

    private void RefreshRecoveryOverlay()
    {
        if (_vm.RecoveryOffer is not { } offer)
        {
            RecoveryOverlay.Visibility = Visibility.Collapsed;
            _recoveryShown = false;
            return;
        }
        RecoveryOverlay.Visibility = Visibility.Visible;
        if (!_recoveryShown) RestoreButton.Focus();
        _recoveryShown = true;
        RecoveryTitle.Text = Loc.Plural(offer.Count, "Restore {0} file?", "Restore {0} files?");
        RecoveryList.Text = string.Join(Environment.NewLine, offer.Select(entry => entry.Meta.Title));
    }

    private void Restore_Click(object sender, RoutedEventArgs e) => _ = _vm.RestoreAsync();

    private void DiscardRecovery_Click(object sender, RoutedEventArgs e) => _vm.DiscardRecovery();

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        _loadingSettings = true;
        (ThemeService.Appearance switch
        {
            AppAppearance.Light => AppearanceLight,
            AppAppearance.Dark => AppearanceDark,
            _ => AppearanceSystem,
        }).IsChecked = true;
        // In the Store package the manifest registers the Open with entry and the address.
        OpenWithSection.Visibility = Packaging.IsPackaged ? Visibility.Collapsed : Visibility.Visible;
        OpenWithToggle.IsChecked = !Packaging.IsPackaged && FileAssociation.IsRegisteredForCurrentUser();
        _loadingSettings = false;
        _settingsOpen = true;
        RefreshOverlays();
        AppearanceSystem.Focus();
    }

    private void SettingsDone_Click(object sender, RoutedEventArgs e)
    {
        _settingsOpen = false;
        RefreshOverlays();
        ReleaseHeld();
    }

    private void SettingsOverlay_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        SettingsDone_Click(sender, e);
        e.Handled = true;
    }

    private void About_Click(object sender, RoutedEventArgs e)
    {
        AboutVersion.Text = Loc.T("Version {0}", AppInfo.Version);
        AboutCopyright.Text = AppInfo.Copyright;
        SetLink(SiteLink, new Uri(AppInfo.Site).Host + new Uri(AppInfo.Site).AbsolutePath.TrimEnd('/'), Loc.T("Website"));
        SetLink(SupportLink, AppInfo.SupportAddress, Loc.T("Email support"));
        AboutNotices.Text = AppInfo.Notices() ?? Loc.T("The notices file is missing from this copy of Lazy PDF. Reinstall the app to get it back.");
        _settingsOpen = false;
        _aboutOpen = true;
        RefreshOverlays();
        AboutDoneButton.Focus();
    }

    private static void SetLink(Button link, string text, string name)
    {
        link.Content = text;
        AutomationProperties.SetName(link, name);
    }

    private void AboutDone_Click(object sender, RoutedEventArgs e)
    {
        _aboutOpen = false;
        RefreshOverlays();
        ReleaseHeld();
    }

    private void AboutOverlay_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        AboutDone_Click(sender, e);
        e.Handled = true;
    }

    private void SiteLink_Click(object sender, RoutedEventArgs e) => Launch(AppInfo.Site);

    private void PrivacyLink_Click(object sender, RoutedEventArgs e) => Launch(AppInfo.PrivacyPage);

    private void SupportLink_Click(object sender, RoutedEventArgs e) => Launch("mailto:" + AppInfo.SupportAddress);

    private void DefaultApps_Click(object sender, RoutedEventArgs e) => Launch("ms-settings:defaultapps");

    private void Launch(string address)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(address) { UseShellExecute = true });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            _vm.ShowProblem(new Problem(Loc.T("Not opened"), Loc.T("Windows could not open {0}.", address)));
        }
    }

    private void Appearance_Checked(object sender, RoutedEventArgs e)
    {
        if (_loadingSettings) return;
        _vm.SetAppearance(sender == AppearanceLight ? AppAppearance.Light : sender == AppearanceDark ? AppAppearance.Dark : AppAppearance.System);
    }

    private void OpenWith_Click(object sender, RoutedEventArgs e)
    {
        bool want = OpenWithToggle.IsChecked == true;
        if (FileAssociation.SetForCurrentUser(want)) return;
        OpenWithToggle.IsChecked = !want;
        _vm.ShowProblem(new Problem(Loc.T("Not changed"), Loc.T("Windows would not let Lazy PDF change this setting. Your account may be managed by someone else.")));
    }
}
