using System.Windows;

namespace LazyPDF.App.Tools.Forms;

internal static class FieldStyles
{
    private static readonly ResourceDictionary Dictionary = new() { Source = new Uri("pack://application:,,,/LazyPDF;component/Tools/Forms/FieldStyles.xaml") };

    public static Style Text => (Style)Dictionary["FieldTextStyle"];

    public static Style Password => (Style)Dictionary["FieldPasswordStyle"];

    public static Style Hit => (Style)Dictionary["FieldHitStyle"];
}
