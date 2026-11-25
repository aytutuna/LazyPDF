using System.Windows;
using System.Windows.Controls;

namespace LazyPDF.App.Tools.Forms;

internal static class FieldStyles
{
    private static readonly ResourceDictionary Dictionary = new() { Source = new Uri("pack://application:,,,/LazyPDF;component/Tools/Forms/FieldStyles.xaml") };

    public static Style Text => (Style)Dictionary["FieldTextStyle"];

    public static Style Password => (Style)Dictionary["FieldPasswordStyle"];

    // A combo box or list on a turned view draws nothing while it is idle, like the text controls: the page shows the
    // value, and a sideways control would not read. Hit testing is not affected by opacity.
    public static Style Idle(FrameworkElement control) => control is ComboBox ? IdleCombo.Value : IdleList.Value;

    private static readonly Lazy<Style> IdleCombo = new(() => MakeIdle(typeof(ComboBox)));

    private static readonly Lazy<Style> IdleList = new(() => MakeIdle(typeof(ListBox)));

    private static Style MakeIdle(Type target)
    {
        var style = new Style(target, (Style)Application.Current.FindResource(target));
        style.Setters.Add(new Setter(UIElement.OpacityProperty, 0.0));
        var focused = new Trigger { Property = UIElement.IsKeyboardFocusWithinProperty, Value = true };
        focused.Setters.Add(new Setter(UIElement.OpacityProperty, 1.0));
        style.Triggers.Add(focused);
        return style;
    }

    public static Style Hit => (Style)Dictionary["FieldHitStyle"];
}
