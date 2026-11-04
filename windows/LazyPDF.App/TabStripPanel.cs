using System.Windows;
using System.Windows.Controls;

namespace LazyPDF.App;

/// <summary>
/// The row of document tabs. Tabs keep their own width until the row is full, then the wider ones give way;
/// below <see cref="MinTab"/> the row runs past the strip and slides so the selected tab stays in view.
/// </summary>
public sealed class TabStripPanel : Panel
{
    private const double MinTab = 128;

    public TabStripPanel() => ClipToBounds = true;

    public bool Overflows { get; private set; }

    public event EventHandler? OverflowChanged;

    // What each tab would take if there were room, kept from the first measure: a tab measured narrower reports a narrower desire.
    private double[] _natural = [];

    protected override Size MeasureOverride(Size available)
    {
        foreach (UIElement child in InternalChildren) child.Measure(new Size(double.PositiveInfinity, available.Height));
        _natural = [.. InternalChildren.Cast<UIElement>().Select(c => c.DesiredSize.Width)];
        var widths = Widths(available.Width);
        double height = 0;
        for (int i = 0; i < widths.Length; i++)
        {
            InternalChildren[i].Measure(new Size(widths[i], available.Height));
            height = Math.Max(height, InternalChildren[i].DesiredSize.Height);
        }
        double width = widths.Sum();
        return new Size(double.IsInfinity(available.Width) ? width : Math.Min(width, available.Width), height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        var widths = Widths(final.Width);
        double total = widths.Sum();
        double shift = 0;
        double x = 0;
        for (int i = 0; i < widths.Length; i++)
        {
            if (InternalChildren[i] is ListBoxItem { IsSelected: true } && x + widths[i] > final.Width) shift = x + widths[i] - final.Width;
            x += widths[i];
        }
        x = -shift;
        for (int i = 0; i < widths.Length; i++)
        {
            InternalChildren[i].Arrange(new Rect(x, 0, widths[i], final.Height));
            x += widths[i];
        }
        bool overflows = total > final.Width + 0.5;
        if (overflows != Overflows)
        {
            Overflows = overflows;
            OverflowChanged?.Invoke(this, EventArgs.Empty);
        }
        return final;
    }

    // The widest width the wider tabs are cut to so that the row fits, but not below MinTab.
    private double[] Widths(double available)
    {
        var natural = _natural;
        if (double.IsInfinity(available) || natural.Sum() <= available) return natural;
        double low = MinTab, high = natural.Max();
        for (int step = 0; step < 24; step++)
        {
            double cap = (low + high) / 2;
            if (natural.Sum(w => Math.Min(w, cap)) > available) high = cap;
            else low = cap;
        }
        return [.. natural.Select(w => Math.Min(w, low))];
    }
}
