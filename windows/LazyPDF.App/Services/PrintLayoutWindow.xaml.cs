using System.Globalization;
using System.Windows;
using System.Windows.Controls;

namespace LazyPDF.App.Services;

/// <summary>Asks for the layout after the system print dialog, which has no place for it and fixes the range and the paper.</summary>
internal sealed partial class PrintLayoutWindow : Window
{
    private readonly IReadOnlyList<int>? _range;
    private readonly int _documentPages;
    private readonly double _sheetWidth, _sheetHeight;
    private readonly bool _ready;

    internal PrintLayoutWindow(IReadOnlyList<int>? range, int documentPages, PrintLayout remembered, double sheetWidth, double sheetHeight, bool rightToLeft)
    {
        _range = range;
        _documentPages = documentPages;
        _sheetWidth = sheetWidth;
        _sheetHeight = sheetHeight;
        InitializeComponent();
        PerSheetBox.ItemsSource = PrintLayout.PerSheetChoices;
        PerSheetBox.SelectedItem = remembered.PerSheet;
        BookletBox.IsChecked = remembered.Booklet;
        BorderBox.IsChecked = remembered.Border;
        BindingBox.SelectedIndex = rightToLeft ? 1 : 0;
        GapBox.Text = (remembered.Gap * 25.4 / 72).ToString("0.#", CultureInfo.CurrentCulture);
        ParityBox.SelectedIndex = 0;
        BookletHint.Text = Loc.T("Two pages on each side of a landscape sheet, in the order that folds into a booklet.");
        _ready = true;
        Changed(this, new RoutedEventArgs());
    }

    /// <summary>The choices, or null when the person cancels. <paramref name="range"/> is the pages the print dialog chose (null for all) and the sheet is in points.</summary>
    public static PrintLayout? Ask(Window? owner, IReadOnlyList<int>? range, int documentPages, PrintLayout remembered, double sheetWidth, double sheetHeight, bool rightToLeft)
    {
        var window = new PrintLayoutWindow(range, documentPages, remembered, sheetWidth, sheetHeight, rightToLeft) { Owner = owner };
        return window.ShowDialog() == true ? window.Current()!.Value.Layout : null;
    }

    // The gap is typed in millimeters; null when it is not a number in range.
    private double? Gap()
    {
        if (string.IsNullOrWhiteSpace(GapBox.Text)) return 0;
        if (!double.TryParse(GapBox.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var mm)) return null;
        double points = mm * 72 / 25.4;
        return points is >= 0 and <= PrintLayout.MaxGap ? points : null;
    }

    internal (PrintLayout Layout, string? Problem)? Current()
    {
        bool imposes = BookletBox.IsChecked == true || (int)PerSheetBox.SelectedItem > 1;
        if ((imposes ? Gap() : 0) is not { } gap) return null;
        var layout = new PrintLayout((int)PerSheetBox.SelectedItem, BookletBox.IsChecked == true, (PrintParity)ParityBox.SelectedIndex,
            ReverseBox.IsChecked == true, BindingBox.SelectedIndex == 1, gap, BorderBox.IsChecked == true);
        return (layout, layout.Validate(_sheetWidth, _sheetHeight));
    }

    private void Changed(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        bool imposes = BookletBox.IsChecked == true || (int)PerSheetBox.SelectedItem > 1;
        PerSheetBox.IsEnabled = BookletBox.IsChecked != true;
        BindingBox.IsEnabled = GapBox.IsEnabled = BorderBox.IsEnabled = imposes;
        var current = Current();
        string? problem = current is null ? Loc.T("Type a gap from 0 to 25 mm.") : current.Value.Problem;
        GapProblem.Text = problem;
        GapProblem.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
        PrintButton.IsEnabled = problem is null;
        SidesHint.Text = current is { Layout: { Booklet: true, Parity: PrintParity.All, Reverse: false } }
            ? Loc.T("Two-sided printing must flip on the short edge.")
            : imposes ? Loc.T("To print both sides by hand, print the odd sides, turn the stack over and print the even sides.")
            : Loc.T("Odd and even go by page number. To print both sides by hand, print the odd pages, turn the stack over and print the even pages.");
        Summary.Text = current is { } c ? c.Layout.Summary(_range, _documentPages) : "";
    }

    private void Print_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
