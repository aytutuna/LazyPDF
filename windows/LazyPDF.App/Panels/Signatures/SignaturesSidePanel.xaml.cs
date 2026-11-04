using System.Windows;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.Core;

namespace LazyPDF.App.Panels.Signatures;

public enum SignatureLevel
{
    Good,
    Caution,
    Bad,
    Unknown,
}

/// <summary>One signature in the list, in the words Core has for it.</summary>
public sealed class SignatureRow(SignatureReport report, int page, Rect where)
{
    public SignatureReport Report { get; } = report;

    /// <summary>The page the signature's field is on, or -1 when it has none.</summary>
    public int Page { get; } = page;

    /// <summary>The field on that page, in page space.</summary>
    public Rect Where { get; } = where;

    public string Title => Report.SignerName ?? Report.FieldName ?? Loc.T("Signature {0}", Report.Index + 1);

    public string Status => SignatureText.Status(Report.Verdict);

    public string Sentence => Report.Sentence;

    public string Summary => Title + ", " + Status + ". " + Sentence;

    public SignatureLevel Level => Report.Verdict switch
    {
        SignatureVerdict.Valid => SignatureLevel.Good,
        SignatureVerdict.ValidButUntrusted => SignatureLevel.Caution,
        SignatureVerdict.ChangedAfterSigning or SignatureVerdict.Broken => SignatureLevel.Bad,
        _ => SignatureLevel.Unknown,
    };

    public string Glyph => Level switch
    {
        SignatureLevel.Good => "",
        SignatureLevel.Caution => "",
        SignatureLevel.Bad => "",
        _ => "",
    };
}

/// <summary>The signatures of the file and what Core found when it checked them; a click shows the field.</summary>
public partial class SignaturesSidePanel : ToolPanel
{
    private int _ticket;

    public SignaturesSidePanel() => InitializeComponent();

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        _ = BuildAsync();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        _ticket++;
        List.ItemsSource = null;
    }

    private void Tab_Changed(object? sender, EventArgs e) => _ = BuildAsync();

    private async Task BuildAsync()
    {
        int ticket = ++_ticket;
        var tab = Tab!;
        if (!tab.Document.IsSigned)
        {
            Show(null, Loc.T("This file has no signatures."));
            return;
        }
        Show(null, Loc.T("Checking the signatures"));
        var bytes = PageBytes(tab);
        var options = new VerifyOptions { Password = tab.Password, Certificate = tab.Certificate };
        IReadOnlyList<SignatureReport>? reports;
        try
        {
            reports = await Task.Run(() => PdfSignatureVerifier.Verify(bytes, options));
        }
        catch (PdfReadException)
        {
            reports = null;
        }
        if (ticket != _ticket) return;
        if (reports is null) Show(null, Loc.T("The signatures could not be checked."));
        else Show(reports.Select(Row).ToList(), reports.Count == 0 ? Loc.T("This file has no signatures.") : null);
    }

    private static byte[] PageBytes(DocumentTab tab) => tab.Session.Current.ToArray();

    private void Show(List<SignatureRow>? rows, string? note)
    {
        List.ItemsSource = rows;
        Note.Text = note ?? "";
        Note.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
    }

    // Finds the field's widget on its page.
    private SignatureRow Row(SignatureReport report)
    {
        var document = Tab!.Document;
        foreach (var annotation in PdfAnnotations.ReadAll(document))
        {
            if (annotation.Type != AnnotationType.Widget || report.FieldName is null || PdfText.Read(document, annotation.Dictionary, "T") != report.FieldName) continue;
            var box = Viewer!.Geometry(annotation.PageIndex).ToDisplay(annotation.Rect);
            return new SignatureRow(report, annotation.PageIndex, new Rect(box.X, box.Y, box.Width, box.Height));
        }
        return new SignatureRow(report, -1, Rect.Empty);
    }

    private void Go(SignatureRow row)
    {
        if (row.Page < 0 || Viewer is not { } viewer) return;
        viewer.GoToPage(row.Page);
        viewer.Reveal(row.Page, row.Where);
    }

    private void List_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is SignatureRow row) Go(row);
    }

    private void List_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && List.SelectedItem is SignatureRow row)
        {
            Go(row);
            e.Handled = true;
        }
    }
}
