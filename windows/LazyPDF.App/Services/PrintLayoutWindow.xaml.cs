using System.Windows;
using System.Windows.Controls;

namespace LazyPDF.App.Services;

/// <summary>Asks for the layout before the system print dialog, which has no place for it.</summary>
internal sealed partial class PrintLayoutWindow : Window
{
    private PrintLayoutWindow()
    {
        InitializeComponent();
        PerSheetBox.ItemsSource = PrintLayout.PerSheetChoices;
        PerSheetBox.SelectedIndex = 0;
        ParityBox.SelectedIndex = 0;
        BookletHint.Text = Loc.T("Two pages on each side of a landscape sheet, in the order that folds into a booklet.");
    }

    /// <summary>The choices, or null when the person cancels.</summary>
    public static PrintLayout? Ask(Window? owner)
    {
        var window = new PrintLayoutWindow { Owner = owner };
        if (window.ShowDialog() != true) return null;
        return new PrintLayout((int)window.PerSheetBox.SelectedItem, window.BookletBox.IsChecked == true, (PrintParity)window.ParityBox.SelectedIndex);
    }

    private void Booklet_Changed(object sender, RoutedEventArgs e) => PerSheetBox.IsEnabled = BookletBox.IsChecked != true;

    private void Print_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
