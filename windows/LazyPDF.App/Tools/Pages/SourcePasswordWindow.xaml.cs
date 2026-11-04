using System.Windows;

namespace LazyPDF.App.Tools.Pages;

/// <summary>Asks for the password of a file a tool is about to read pages from.</summary>
internal sealed partial class SourcePasswordWindow : Window
{
    private SourcePasswordWindow(string name, bool wrong)
    {
        InitializeComponent();
        Title = Loc.T("Password needed");
        Message.Text = Loc.T("{0} needs a password to open.", name);
        Wrong.Visibility = wrong ? Visibility.Visible : Visibility.Collapsed;
        Loaded += (_, _) => Input.Focus();
    }

    public static string? Ask(string name, bool wrong)
    {
        var window = new SourcePasswordWindow(name, wrong) { Owner = Application.Current?.MainWindow };
        return window.ShowDialog() == true ? window.Input.Password : null;
    }

    private void Open_Click(object sender, RoutedEventArgs e) => DialogResult = true;
}
