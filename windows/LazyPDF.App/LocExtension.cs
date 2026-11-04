// From Lazy Scan's LocExtension.cs.
using System.Windows.Markup;

namespace LazyPDF.App;

// {loc:T Save} in XAML. English is the key, as in Loc.T. Text with a comma, apostrophe or "="
// needs a backslash or quotes: {loc:T 'Don\'t save, close'} or {loc:T Don\'t save\, close}.
// Text that starts with a brace takes a leading {}: {loc:T {}{0} pages}.
[MarkupExtensionReturnType(typeof(string))]
public sealed class TExtension : MarkupExtension
{
    public TExtension(string text) => Text = text;

    public string Text { get; }

    public override object ProvideValue(IServiceProvider serviceProvider) =>
        Loc.T(Text);
}
