using System.Security.Cryptography.X509Certificates;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Protect;

public enum ProtectMode { Password, Certificates, Remove }

/// <summary>
/// A password to open the file, limits on what people may do, or certificates for the people who may open it;
/// or the protection taken off. The result is a rewrite, so it opens as a new document and the file in view stays as it was.
/// </summary>
public partial class ProtectPanel : ToolPanel
{
    private readonly List<Recipient> _recipients = [];

    public ProtectPanel()
    {
        InitializeComponent();
        ModePassword.IsChecked = true;
        ShowRecipients();
    }

    public override ToolAction? Action => Mode switch
    {
        ProtectMode.Remove => new ToolAction(Loc.T("Remove protection"), "\uE785", CanRun, RunAsync),
        ProtectMode.Certificates => new ToolAction(Loc.T("Protect for them"), "\uE72E", CanRun, RunAsync),
        _ => new ToolAction(Loc.T("Protect the file"), "\uE72E", CanRun, RunAsync),
    };

    private ProtectMode Mode => ModeRemove.IsChecked == true ? ProtectMode.Remove : ModeCertificates.IsChecked == true ? ProtectMode.Certificates : ProtectMode.Password;

    private bool Limited => LimitToggle.IsChecked == true;

    private string Opening => OpenBox.Password;

    private PdfCryptStrength Strength => StrengthBox.SelectedIndex == 1 ? PdfCryptStrength.Aes128 : PdfCryptStrength.Aes256;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        var document = Tab!.Document;
        ModeRemove.Visibility = document.IsEncrypted ? Visibility.Visible : Visibility.Collapsed;
        if (!document.IsEncrypted && Mode == ProtectMode.Remove) ModePassword.IsChecked = true;
        UpdateState();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        UnlockBox.Clear();
        OpenBox.Clear();
        RepeatBox.Clear();
        OwnerBox.Clear();
        _recipients.Clear();
        ShowRecipients();
    }

    private bool Locked => Tab is { } tab && ProtectWork.IsLockedAgainstChange(tab.Document);

    // A certificate holder without the right to change the protection has no password to give.
    private bool LockedForGood => Locked && Tab!.Document.Security is { IsPublicKey: true };

    private bool CanRun()
    {
        if (Tab is null || LockedForGood || Locked && UnlockBox.Password.Length == 0) return false;
        return Mode switch
        {
            ProtectMode.Remove => Tab.Document.IsEncrypted,
            ProtectMode.Certificates => _recipients.Count > 0,
            _ => ProtectWork.PasswordsAgree(Opening, RepeatBox.Password, Limited, OwnerBox.Password),
        };
    }

    private void UpdateState()
    {
        if (Tab is not { } tab) return;
        var mode = Mode;
        bool locked = Locked;
        bool stuck = LockedForGood;
        UnlockSection.Visibility = locked && !stuck ? Visibility.Visible : Visibility.Collapsed;
        ModeTrack.Visibility = stuck ? Visibility.Collapsed : Visibility.Visible;
        RemoveNote.Visibility = !stuck && mode == ProtectMode.Remove ? Visibility.Visible : Visibility.Collapsed;
        PasswordSection.Visibility = !stuck && mode == ProtectMode.Password ? Visibility.Visible : Visibility.Collapsed;
        RecipientSection.Visibility = !stuck && mode == ProtectMode.Certificates ? Visibility.Visible : Visibility.Collapsed;
        LimitSection.Visibility = StrengthSection.Visibility = !stuck && mode != ProtectMode.Remove ? Visibility.Visible : Visibility.Collapsed;
        LimitDetails.Visibility = Limited ? Visibility.Visible : Visibility.Collapsed;
        OwnerRow.Visibility = mode == ProtectMode.Password ? Visibility.Visible : Visibility.Collapsed;
        CanPrintSharp.IsEnabled = CanPrint.IsChecked == true;
        if (CanComment.IsChecked == true) CanFill.IsChecked = true;
        CanFill.IsEnabled = CanComment.IsChecked != true;
        LimitNote.Text = mode == ProtectMode.Certificates
            ? Loc.T("These limits are a request, not a lock. Some programs ignore them. Only the certificates keep the file private.")
            : Loc.T("These limits are a request, not a lock. Some programs ignore them. Only a password to open keeps the file private.");
        StrengthNote.Text = Strength == PdfCryptStrength.Aes128 && (Opening + OwnerBox.Password).Any(c => c > '\u00FF')
            ? Loc.T("Older readers may not accept these letters. Use AES 256-bit.") : "";

        var strength = PasswordStrength.Rate(Opening);
        StrengthBar.Value = (int)strength;
        StrengthHint.Text = PasswordStrength.Hint(strength);
        PasswordNote.Text = RepeatBox.Password.Length > 0 && RepeatBox.Password != Opening ? Loc.T("The passwords do not match.") : "";
        OwnerNote.Text = !Limited || mode != ProtectMode.Password ? ""
            : OwnerBox.Password.Length == 0 ? Loc.T("Type a Permissions password to apply the limits.")
            : OwnerBox.Password == Opening ? Loc.T("Use a different password here.") : "";
        RecipientNote.Text = _recipients.Count == 0 ? Loc.T("Add at least one certificate.")
            : _recipients.Any(r => r.HasPrivateKey) ? "" : Loc.T("None of these has its key on this computer. You could not open the copy. Add your own certificate too.");

        var document = tab.Document;
        StateGlyph.Text = locked ? "\uE7BA" : "\uE946";
        StateNote.Text = stuck ? Loc.T("Opened with limited rights. Your certificate may not change the protection.")
            : locked ? Loc.T("Opened with limited rights. Enter its permissions password to change the protection.")
            : !document.IsEncrypted ? Loc.T("This file is not protected.")
            : document.Security is { IsPublicKey: true } ? Loc.T("Protected for certificate holders.")
            : Loc.T("Protected with a password.");

        WarnNote.Text = string.Join(" ", new[]
        {
            document.IsSigned ? Loc.T("The copy will not keep the signatures.") : null,
            document.PdfAPart is not null && mode != ProtectMode.Remove ? Loc.T("The copy will no longer be PDF/A.") : null,
        }.OfType<string>());
        WarnRow.Visibility = WarnNote.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        RaiseActionChanged();
    }

    private void Tab_Changed(object? sender, EventArgs e) => UpdateState();

    private void Mode_Checked(object sender, RoutedEventArgs e) => UpdateState();

    private void Password_Changed(object sender, RoutedEventArgs e) => UpdateState();

    private void Limit_Click(object sender, RoutedEventArgs e) => UpdateState();

    private void Choice_Click(object sender, RoutedEventArgs e) => UpdateState();

    private void Strength_Changed(object sender, SelectionChangedEventArgs e) => UpdateState();

    private PermissionChoices Choices() => !Limited ? PermissionChoices.Everything
        : new(CanPrint.IsChecked == true, CanPrintSharp.IsChecked == true, CanCopy.IsChecked == true, CanEdit.IsChecked == true,
              CanComment.IsChecked == true, CanFill.IsChecked == true, CanAssemble.IsChecked == true);

    private async Task RunAsync()
    {
        var tab = Tab!;
        var host = Host!;
        var mode = Mode;
        var allowed = Choices().ToPermissions();
        string open = Opening;
        string owner = Limited ? OwnerBox.Password : open;
        var strength = Strength;
        var recipients = _recipients.Select(r => r.ToPdfRecipient(allowed)).ToList();
        byte[] bytes = tab.Session.Current.ToArray();
        bool locked = Locked;
        string? password = locked ? UnlockBox.Password : tab.Password;
        var certificate = tab.Certificate;
        string name = System.IO.Path.GetFileNameWithoutExtension(tab.Title);

        byte[]? made = null;
        X509Certificate2? opener = null;
        bool refused = false;
        try
        {
            await host.RunBusyAsync(mode == ProtectMode.Remove ? Loc.T("Removing protection") : Loc.T("Protecting the file"), token => Task.Run(() =>
            {
                using var document = certificate is null ? PdfDocument.Open(bytes, password) : PdfDocument.Open(bytes, certificate);
                if (locked && document.Security is not { OpenedAsOwner: true })
                {
                    refused = true;
                    return;
                }
                token.ThrowIfCancellationRequested();
                byte[] result;
                X509Certificate2? by = null;
                switch (mode)
                {
                    case ProtectMode.Remove:
                        result = ProtectWork.Remove(document);
                        break;
                    case ProtectMode.Certificates:
                        (result, by) = ProtectWork.ForRecipients(document, recipients, strength);
                        break;
                    default:
                        result = ProtectWork.WithPassword(document, open, owner, allowed, strength);
                        break;
                }
                token.ThrowIfCancellationRequested();
                made = result;
                opener = by;
            }, token));
        }
        catch (PdfReadException e) when (locked && e.Problem == PdfReadProblem.PasswordRequired)
        {
            refused = true;
        }
        catch (UnauthorizedAccessException)
        {
            host.ShowProblem(new Problem(Loc.T("Protection is locked"), Loc.T("Enter the permissions password, then try again.")));
            return;
        }
        catch (Exception e) when (e is PdfReadException or InvalidDataException or System.Security.Cryptography.CryptographicException)
        {
            host.ShowProblem(new Problem(Loc.T("Could not protect the file"), Loc.T("The file could not be rewritten. Save a copy, then protect that.")));
            System.Diagnostics.Trace.TraceError(e.ToString());
            return;
        }

        if (refused)
        {
            host.ShowProblem(new Problem(Loc.T("Wrong password"), Loc.T("That is not the permissions password. Check it and try again.")));
            return;
        }
        if (made is null) return;

        string suffix = mode == ProtectMode.Remove ? Loc.T("unprotected") : Loc.T("protected");
        string title = $"{name} {suffix}.pdf";
        if (mode == ProtectMode.Certificates && opener is null)
        {
            if (!await SaveCopyAsync(host, made, title)) return;
            host.SetStatus(Loc.T("Protected copy saved."));
            host.ShowNotice(Loc.T("Copy for the others"), Loc.T("You cannot open it here. Send it to the people you chose."));
        }
        else
        {
            if (!await host.OpenNewAsync(made, title, mode == ProtectMode.Password && open.Length > 0 ? open : null, opener)) return;
            host.SetStatus(mode == ProtectMode.Remove ? Loc.T("Protection removed from a copy.") : Loc.T("Protected copy made."));
            host.ShowNotice(mode == ProtectMode.Remove ? Loc.T("Copy without protection") : Loc.T("Copy with protection"),
                            Loc.T("The original is unchanged. Save the copy to keep it."));
        }
        UnlockBox.Clear();
        OpenBox.Clear();
        RepeatBox.Clear();
        OwnerBox.Clear();
    }

    // The copy is for other people's keys, so it cannot be a tab here: nobody could open it.
    private async Task<bool> SaveCopyAsync(IToolHost host, byte[] bytes, string title)
    {
        var dialog = new SaveFileDialog { FileName = title, DefaultExt = ".pdf", Filter = Loc.T("PDF files") + "|*.pdf" };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return false;
        try
        {
            await File.WriteAllBytesAsync(dialog.FileName, bytes);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(Problems.Save(e, System.IO.Path.GetFileName(dialog.FileName)));
            return false;
        }
    }
}
