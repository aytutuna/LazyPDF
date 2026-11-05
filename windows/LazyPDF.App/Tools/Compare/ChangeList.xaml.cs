using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace LazyPDF.App.Tools.Compare;

/// <summary>The differences of a comparison, one row each; a click raises <see cref="Picked"/>.</summary>
internal sealed partial class ChangeList : UserControl
{
    private bool _setting;

    public ChangeList() => InitializeComponent();

    public event EventHandler<ChangeRow>? Picked;

    public IReadOnlyList<ChangeRow> Rows
    {
        set
        {
            _setting = true;
            List.ItemsSource = value;
            _setting = false;
        }
    }

    // Selecting a row raises the event; a row that is already selected needs the click itself.
    private void List_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (ItemsControl.ContainerFromElement(List, (DependencyObject)e.OriginalSource) is ListBoxItem { IsSelected: true, DataContext: ChangeRow row })
            Picked?.Invoke(this, row);
    }

    private void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_setting && List.SelectedItem is ChangeRow row) Picked?.Invoke(this, row);
    }
}
