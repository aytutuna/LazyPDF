using System.Windows;

namespace LazyPDF.App.Tools.Create;

/// <summary>Makes a new document from the Home tab, where no document is open for the panel to sit beside.</summary>
public partial class CreateWindow : Window
{
    private CreateRequest? _request;

    private CreateWindow()
    {
        InitializeComponent();
        Panel.ActionChanged += (_, _) => CreateButton.IsEnabled = Panel.Action!.CanRun();
        CreateButton.IsEnabled = Panel.Action!.CanRun();
    }

    /// <summary>Asks what to make, then makes it and opens it in a new tab.</summary>
    public static async Task RunAsync(Window owner, IToolHost host)
    {
        var window = new CreateWindow { Owner = owner };
        if (window.ShowDialog() == true && window._request is { } request) await window.Panel.CreateAsync(host, request);
    }

    private void CreateButton_Click(object sender, RoutedEventArgs e)
    {
        _request = Panel.Request();
        if (_request is not null) DialogResult = true;
    }
}
