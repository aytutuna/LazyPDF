using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.FillSign;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Certificates;

/// <summary>Sign with a certificate from Windows or a PFX file, add validation data to signatures a file already has.</summary>
public partial class CertificatesPanel : ToolPanel
{
    private enum WhereKind
    {
        Invisible,
        Box,
        Field,
    }

    private sealed record WhereChoice(string Text, WhereKind Kind, string? Field = null);

    private sealed record CertifyChoice(string Text, CertificationLevel Level);

    private sealed record LookChoice(string Text, bool Picture, bool Words);

    private sealed record OneOffRow(string Name, BitmapSource Picture);

    private readonly SystemFontSource _fonts = new();
    private readonly SavedSignatures _saved;
    private string? _pfx;
    private SignatureBoxTool? _tool;
    private int _boxPage;
    private Rect? _box;
    private Rectangle? _outline;
    private bool _working;
    private bool _refilling;
    private object? _boxPageKey;
    private PdfRgbaImage? _oneOff;

    public CertificatesPanel()
        : this(SavedSignatures.DefaultDirectory)
    {
    }

    internal CertificatesPanel(string savedDirectory)
    {
        _saved = new SavedSignatures(savedDirectory);
        InitializeComponent();
        CertifyBox.ItemsSource = new CertifyChoice[]
        {
            new(Loc.T("Do not certify"), CertificationLevel.None),
            new(Loc.T("No changes allowed"), CertificationLevel.NoChanges),
            new(Loc.T("Form filling allowed"), CertificationLevel.FormFill),
            new(Loc.T("Form filling and comments allowed"), CertificationLevel.Annotate),
        };
        CertifyBox.SelectedIndex = 0;
        LookBox.ItemsSource = new LookChoice[]
        {
            new(Loc.T("Text only"), false, true),
            new(Loc.T("Picture and text"), true, true),
            new(Loc.T("Picture only"), true, false),
        };
        LookBox.SelectedIndex = 0;
    }

    public override ToolAction? Action => new(Loc.T("Sign"), "\uEB95", () => CanSign, SignAsync);

    private bool UseStore => StoreMode.IsChecked == true;

    private WhereChoice? Where => WhereBox.SelectedItem as WhereChoice;

    private LookChoice? Look => LookBox.SelectedItem as LookChoice;

    private bool CanSign =>
        !_working
        && (Look is not { Picture: true } || Where?.Kind == WhereKind.Invisible || SavedList.SelectedItem is not null)
        && (UseStore ? CertBox.SelectedItem is not null : _pfx is not null)
        && (Where is { Kind: not WhereKind.Box } || _box is not null)
        && (StampSwitch.IsChecked != true || CertificateSigning.IsWebAddress(UrlBox.Text));

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        if (UrlBox.Text.Length == 0) UrlBox.Text = SigningSettingsStore.Load().TimestampUrl;
        string? chosen = (CertBox.SelectedItem as CertificateChoice)?.Thumbprint;
        var certificates = WindowsCertificates.WithPrivateKey(forSigning: true);
        CertBox.ItemsSource = certificates;
        int again = certificates.ToList().FindIndex(c => c.Thumbprint == chosen);
        CertBox.SelectedIndex = again >= 0 ? again : certificates.Count > 0 ? 0 : -1;
        ShowCertificateNote();
        FillSaved();
        Refill();
        if (Host!.TakeSigningField() is { } field && WhereBox.ItemsSource is IEnumerable<WhereChoice> places)
        {
            WhereBox.SelectedItem = places.FirstOrDefault(p => p.Field == field) ?? WhereBox.SelectedItem;
        }
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        Stop();
        ClearBox();
        _oneOff = null;
        WhereBox.ItemsSource = null;
        FilePassword.Clear();
    }

    private void FillSaved()
    {
        var rows = new List<object>();
        if (_oneOff is not null) rows.Add(new OneOffRow(Loc.T("This signature only"), SignatureArt.ToBitmap(_oneOff)));
        foreach (var item in _saved.List(SavedKind.Signature))
        {
            if (_saved.Load(item) is { } image) rows.Add(new SavedRow(item, SignatureArt.ToBitmap(image)));
        }
        SavedList.ItemsSource = rows;
        SavedList.SelectedIndex = rows.Count > 0 ? 0 : -1;
        NoneSaved.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowLook()
    {
        LookRow.Visibility = Where?.Kind == WhereKind.Invisible ? Visibility.Collapsed : Visibility.Visible;
        LookPage.Visibility = Look is { Picture: true } ? Visibility.Visible : Visibility.Collapsed;
        if (Look is not { Picture: true }) CloseMaker();
    }

    private void CloseMaker()
    {
        Maker.Visibility = Visibility.Collapsed;
        NewButton.Visibility = Visibility.Visible;
    }

    private void New_Click(object sender, RoutedEventArgs e)
    {
        Maker.Reset();
        Maker.Visibility = Visibility.Visible;
        NewButton.Visibility = Visibility.Collapsed;
    }

    private void Maker_Made(object? sender, EventArgs e)
    {
        var image = Maker.Image!;
        CloseMaker();
        if (Maker.Keep)
        {
            _oneOff = null;
            var item = _saved.Add(SavedKind.Signature, image);
            FillSaved();
            SavedList.SelectedIndex = ((List<object>)SavedList.ItemsSource).FindIndex(r => r is SavedRow row && row.Item == item);
        }
        else
        {
            _oneOff = image;
            FillSaved();
        }
    }

    private void Maker_Cancelled(object? sender, EventArgs e) => CloseMaker();

    private void LookBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ShowLook();
        RaiseActionChanged();
    }

    private void SavedList_SelectionChanged(object sender, SelectionChangedEventArgs e) => RaiseActionChanged();

    private void Tab_Changed(object? sender, EventArgs e)
    {
        Refill();
    }

    // What depends on the file: its empty signature fields, and whether it can still be certified.
    private void Refill()
    {
        var document = Tab!.Document;
        var choices = new List<WhereChoice> { new(Loc.T("Not visible"), WhereKind.Invisible), new(Loc.T("A box I draw on the page"), WhereKind.Box) };
        choices.AddRange(CertificateSigning.EmptyFields(document).Select(name => new WhereChoice(Loc.T("Field {0}", name), WhereKind.Field, name)));
        int kept = CertificateSigning.KeptPlace(WhereBox.SelectedIndex, Where?.Field, choices.Skip(2).Select(c => c.Field!).ToList());
        bool keepBox = kept == 1 && _box is not null && _boxPage < Tab.PageCount && PageKey(_boxPage).Equals(_boxPageKey);
        if (keepBox) Viewer!.Overlay(_boxPage).Children.Remove(_outline!);
        else
        {
            Stop();
            ClearBox();
        }
        _refilling = true;
        try
        {
            WhereBox.ItemsSource = choices;
            WhereBox.SelectedIndex = kept;
        }
        finally
        {
            _refilling = false;
        }
        if (keepBox) Viewer!.Overlay(_boxPage).Children.Add(_outline!);
        else if (kept == 1) BoxText.Text = Loc.T("No box yet.");
        BoxRow.Visibility = Where?.Kind == WhereKind.Box ? Visibility.Visible : Visibility.Collapsed;
        ShowLook();
        bool signed = document.IsSigned;
        CertifyBox.IsEnabled = !signed;
        if (signed) CertifyBox.SelectedIndex = 0;
        CertifyNote.Visibility = signed ? Visibility.Visible : Visibility.Collapsed;
        ExistingPage.Visibility = signed ? Visibility.Visible : Visibility.Collapsed;
        RaiseActionChanged();
    }

    // The box is in page space, so it only holds while the page keeps its object, size and turn.
    private object PageKey(int page)
    {
        var p = Tab!.Document.Pages[page];
        var g = new PageGeometry(p);
        return (p.Reference, g.Matrix, g.Width, g.Height);
    }

    private void ShowCertificateNote()
    {
        string? note = CertBox.Items.Count == 0 ? Loc.T("Windows has no certificate you can sign with. Use a PFX file.")
            : CertBox.SelectedItem is CertificateChoice { IsValidNow: false } ? Loc.T("This certificate is not valid today. The signature will show as not trusted.")
            : null;
        CertNoteText.Text = note ?? "";
        CertNote.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Source_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsInitialized) return;
        StorePage.Visibility = UseStore ? Visibility.Visible : Visibility.Collapsed;
        FilePage.Visibility = UseStore ? Visibility.Collapsed : Visibility.Visible;
        RaiseActionChanged();
    }

    private void CertBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ShowCertificateNote();
        RaiseActionChanged();
    }

    private void ChooseFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = Loc.T("Choose a PFX file"), Filter = Loc.T("Certificate files") + "|*.pfx;*.p12" };
        if (dialog.ShowDialog() != true) return;
        _pfx = dialog.FileName;
        FileName.Text = System.IO.Path.GetFileName(_pfx);
        RaiseActionChanged();
    }

    private void FilePassword_PasswordChanged(object sender, RoutedEventArgs e) => RaiseActionChanged();

    private void WhereBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_refilling) return;
        Stop();
        ClearBox();
        BoxRow.Visibility = Where?.Kind == WhereKind.Box ? Visibility.Visible : Visibility.Collapsed;
        BoxText.Text = Loc.T("No box yet.");
        ShowLook();
        RaiseActionChanged();
    }

    private void DrawBox_Click(object sender, RoutedEventArgs e)
    {
        Stop();
        ClearBox();
        _tool = new SignatureBoxTool(Viewer!, BoxDrawn, Stop);
        Viewer!.PointerTool = _tool;
        BoxText.Text = Loc.T("Drag on the page where it goes.");
    }

    private void BoxDrawn(int page, Rect box)
    {
        Stop();
        _boxPage = page;
        _boxPageKey = PageKey(page);
        _box = box;
        _outline = SignatureBoxTool.Outline();
        SignatureBoxTool.Place(_outline, box);
        Viewer!.Overlay(page).Children.Add(_outline);
        BoxText.Text = Loc.T("Box drawn on page {0}.", page + 1);
        RaiseActionChanged();
    }

    private void Stop()
    {
        if (_tool is null) return;
        var tool = _tool;
        _tool = null;
        if (ReferenceEquals(Viewer?.PointerTool, tool)) Viewer!.PointerTool = null;
    }

    private void ClearBox()
    {
        if (_outline is not null) Viewer?.Overlay(_boxPage).Children.Remove(_outline);
        _outline = null;
        _box = null;
    }

    private void Stamp_Changed(object sender, RoutedEventArgs e)
    {
        StampPage.Visibility = StampSwitch.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        RaiseActionChanged();
    }

    private void UrlBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        UrlNote.Visibility = UrlBox.Text.Trim().Length > 0 && !CertificateSigning.IsWebAddress(UrlBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        RaiseActionChanged();
    }

    private SignChoices Choices(X509Certificate2 certificate, SignatureLook? look)
    {
        var where = Where!;
        PdfRect? rect = where.Kind == WhereKind.Box && _box is { } box
            ? Viewer!.Geometry(_boxPage).ToUser(new DisplayRect(box.X, box.Y, box.Width, box.Height))
            : null;
        return new SignChoices(certificate, where.Field, where.Kind == WhereKind.Box ? _boxPage : 0, rect, ReasonBox.Text, PlaceBox.Text,
            ((CertifyChoice)CertifyBox.SelectedItem).Level, StampSwitch.IsChecked == true ? UrlBox.Text.Trim() : null, LongSwitch.IsChecked == true, look);
    }

    private async Task SignAsync()
    {
        var tab = Tab!;
        var host = Host!;
        if (CertificateSigning.Refusal(tab.Document, Where!.Kind != WhereKind.Field) is { } refusal)
        {
            host.ShowProblem(refusal);
            return;
        }
        // The controls can change while the signing waits on a server, so what they say is read now.
        SignatureLook? look = null;
        if (Where!.Kind != WhereKind.Invisible && Look is { Picture: true } choice)
        {
            if ((SavedList.SelectedItem is SavedRow row ? _saved.Load(row.Item) : _oneOff) is not { } image)
            {
                host.ShowProblem(new Problem(Loc.T("Signature not read"), Loc.T("That saved signature could not be read. Choose another.")));
                return;
            }
            look = choice.Words ? new SignatureLook { Image = image } : new SignatureLook { Image = image, Text = "" };
        }
        bool fromStore = UseStore, stamped = StampSwitch.IsChecked == true;
        X509Certificate2 certificate;
        try
        {
            certificate = fromStore ? ((CertificateChoice)CertBox.SelectedItem).Certificate : PdfDigitalId.ImportPfx(File.ReadAllBytes(_pfx!), FilePassword.Password);
        }
        catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(new Problem(Loc.T("Certificate not opened"), Loc.T("The PFX file could not be opened. Check the password and that the file is a PFX.")));
            return;
        }
        var choices = Choices(certificate, look);
        var verify = SigningSettingsStore.Load().Verify(tab.Password, tab.Certificate, DateTimeOffset.Now);
        int before = tab.Session.Current.Length;
        bool finished = false, covered = true;
        using var transport = new HttpSignatureTransport();
        SetWorking(true);
        try
        {
            await host.RunBusyAsync(Loc.T("Signing the file"), token =>
            {
                transport.Cancel = token;
                return Task.Run(() =>
                {
                    CertificateSigning.Sign(tab.Session, choices, new CancellableTransport(transport, token), _fonts, DateTimeOffset.Now);
                    finished = true;
                    if (choices.LongTerm) covered = CertificateSigning.RevocationCovered(tab.Session.Current.ToArray(), verify);
                }, token);
            });
        }
        catch (Exception e) when (e is InvalidOperationException or ArgumentException or CryptographicException or PdfReadException)
        {
            host.ShowProblem(Failure(e, transport, Loc.T("Not signed")));
        }
        finally
        {
            if (!fromStore) certificate.Dispose();
            SetWorking(false);
            if (tab.Session.Current.Length != before)
            {
                ClearBox();
                if (_oneOff is not null)
                {
                    _oneOff = null;
                    FillSaved();
                }
            }
            if (!finished || tab.Session.Current.Length != before) tab.Reload();
        }
        if (tab.Session.Current.Length == before) return;
        if (stamped) SigningSettingsStore.Update(s => s.TimestampUrl = choices.TimestampUrl ?? "");
        if (!finished)
        {
            host.SetStatus(Loc.T("Signed without validation data."));
            return;
        }
        host.SetStatus(Loc.T("File signed."));
        if (!covered) NoProof(host, transport);
    }

    private async void AddValidation_Click(object sender, RoutedEventArgs e)
    {
        var tab = Tab!;
        var host = Host!;
        if (CertificateSigning.Refusal(tab.Document, newField: false) is { } refusal)
        {
            host.ShowProblem(refusal);
            return;
        }
        string where;
        if (tab.Certificate is not null) where = Loc.T("the servers named in its certificates");
        else
        {
            var hosts = await ServerPreview.HostsAsync(tab.Session.Current.ToArray(), tab.Password);
            where = hosts.Count == 0 ? "" : ServerPreview.Describe(hosts);
        }
        if (where.Length == 0) await Start();
        else host.ShowNotice(Loc.T("These servers will be asked"),
            Loc.T("Lazy PDF will contact {0}. Servers named by certificates found on the way may be asked too. The file itself is not sent.", where),
            new NoticeAction(Loc.T("Ask them"), () => _ = Start()));

        async Task Start()
        {
            var verify = SigningSettingsStore.Load().Verify(tab.Password, tab.Certificate, DateTimeOffset.Now);
            int before = tab.Session.Current.Length;
            bool finished = false, covered = true;
            using var transport = new HttpSignatureTransport();
            SetWorking(true);
            try
            {
                await host.RunBusyAsync(Loc.T("Adding validation data"), token =>
                {
                    transport.Cancel = token;
                    return Task.Run(() =>
                    {
                        CertificateSigning.AddValidation(tab.Session, new CancellableTransport(transport, token), DateTimeOffset.Now);
                        finished = true;
                        covered = CertificateSigning.RevocationCovered(tab.Session.Current.ToArray(), verify);
                    }, token);
                });
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                host.ShowProblem(Failure(error, transport, Loc.T("Validation data not added")));
                return;
            }
            finally
            {
                SetWorking(false);
                if (!finished || tab.Session.Current.Length != before) tab.Reload();
            }
            if (!finished) return;
            if (tab.Session.Current.Length == before)
            {
                host.SetStatus(Loc.T("Nothing new to add."));
                return;
            }
            if (covered) host.SetStatus(Loc.T("Validation data added."));
            else NoProof(host, transport);
        }
    }

    // The panel stays shut while the file is being worked on, so nothing else touches the session the worker uses.
    private void SetWorking(bool working)
    {
        _working = working;
        IsEnabled = !working;
        RaiseActionChanged();
    }

    private static void NoProof(IToolHost host, HttpSignatureTransport transport)
    {
        host.SetStatus(Loc.T("Added without proof of revocation."));
        string advice = Loc.T("The signature may not be checkable after its certificate expires. Add validation data again when the servers answer.");
        host.ShowNotice(Loc.T("Proof of revocation is missing"), transport.LastFailure is { } why ? why + " " + advice : advice);
    }

    // Core's sentence says what failed; the transport knows why a server could not be reached.
    private static Problem Failure(Exception error, HttpSignatureTransport transport, string title) => error switch
    {
        CryptographicException => new(Loc.T("Key cannot be used"), Loc.T("Windows would not let Lazy PDF use this key. Check the PIN or choose another certificate.")),
        PdfReadException => new(Loc.T("File cannot be signed"), Loc.T("The file could not be read for signing. Save it under another name and try again.")),
        InvalidOperationException or ArgumentException => new(title, transport.LastFailure is { } why ? error.Message + " " + why : error.Message),
        _ => new(Loc.T("Something went wrong"), Loc.T("{0} could not be finished. If part of it was done, Undo takes it back.", title)),
    };
}
