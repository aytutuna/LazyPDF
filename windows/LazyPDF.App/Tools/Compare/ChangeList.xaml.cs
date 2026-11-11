using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace LazyPDF.App.Tools.Compare;

/// <summary>The differences of a comparison, one row each; a click raises <see cref="Picked"/>.</summary>
internal sealed partial class ChangeList : UserControl
{
    private bool _setting;

    public ChangeList() => InitializeComponent();

    public event EventHandler<ChangeRow>? Picked;

    /// <summary>Raised when a step went past an end; true when it is back at the first row.</summary>
    public event EventHandler<bool>? Wrapped;

    public IReadOnlyList<ChangeRow> Rows
    {
        set
        {
            _setting = true;
            List.ItemsSource = value;
            _setting = false;
        }
    }

    public bool Step(int by)
    {
        int count = List.Items.Count;
        if (count == 0) return false;
        int from = List.SelectedIndex;
        int to = from < 0 ? (by > 0 ? 0 : count - 1) : ((from + by) % count + count) % count;
        if (from >= 0 && (from + by < 0 || from + by >= count)) Wrapped?.Invoke(this, to == 0);
        if (to == from) Picked?.Invoke(this, (ChangeRow)List.SelectedItem);
        else List.SelectedIndex = to;
        List.ScrollIntoView(List.SelectedItem);
        return true;
    }

    // Alt+Down and Alt+Up step through the rows, except where a combo box uses Alt+Down to open.
    public void HandleKey(KeyEventArgs e)
    {
        if (Keyboard.Modifiers != ModifierKeys.Alt || e.SystemKey is not (Key.Down or Key.Up)) return;
        for (var d = e.OriginalSource as DependencyObject; d is not null; d = d is Visual ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d))
            if (d is ComboBox) return;
        e.Handled = Step(e.SystemKey == Key.Down ? 1 : -1);
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
