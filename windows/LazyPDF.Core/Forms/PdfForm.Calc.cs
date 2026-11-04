namespace LazyPDF.Core;

public sealed partial class PdfForm
{
    private const int MaxCalculations = 10_000;

    public IReadOnlyList<FormScript> Scripts => FormScripts.List(this);

    /// <summary>The fields of /AcroForm /CO, the order calculations run in (ISO 32000-1 12.7.2).</summary>
    public IReadOnlyList<FormField> CalculationOrder
    {
        get
        {
            var order = new List<FormField>();
            if (_document.Array(AcroForm, "CO") is not { } co) return order;
            foreach (var item in co.Items.Take(MaxCalculations))
            {
                if (_document.Resolve(item) is PdfDictionary d && Current(d) is { } listed) order.Add(listed);
            }
            return order;
        }
    }

    /// <summary>
    /// Runs the calculation order. Only the AFSimple_Calculate calls run (sum, average, product, minimum,
    /// maximum of named fields); any other script is returned in <see cref="FormCalculation.NotRun"/>
    /// and its field keeps its value.
    /// </summary>
    public FormCalculation Recalculate()
    {
        RequireFillable();
        int changed = 0;
        var notRun = new List<FormScript>();
        foreach (var listed in CalculationOrder)
        {
            if (FormScripts.SourceOf(this, listed, "C") is not { } source) continue;
            if (FormScriptParser.Parse(source) is not { } calls)
            {
                notRun.Add(new FormScript(listed.Name, "C", source, false));
                continue;
            }
            foreach (var call in calls)
            {
                if (Current(listed.Dictionary) is not { } field || FormFunctions.Calculate(call, ValuesOfFields) is not { } result) continue;
                if (SameValue(field.Value, result) || Prepare(field, [result]) is not { } change) continue;
                Commit([change]);
                changed++;
            }
        }
        return new FormCalculation(changed, notRun);
    }

    /// <summary>
    /// What the field's keystroke and validate scripts say about <paramref name="value"/>: null when it
    /// passes, else the sentence to show. Only built-in functions are checked.
    /// </summary>
    public string? Validate(FormField field, string value)
    {
        foreach (string evt in (ReadOnlySpan<string>)["K", "V"])
        {
            if (FormScripts.CallsOf(this, field, evt) is not { } calls) continue;
            foreach (var call in calls)
            {
                if (FormFunctions.Check(call, value) is { } message) return message;
            }
        }
        return null;
    }

    /// <summary>The text the field shows: its value through the built-in format script, if it has one.</summary>
    public string DisplayText(FormField field) => DisplayOf(field).Text;

    private FormField? Current(PdfDictionary dictionary) => _byDictionary.GetValueOrDefault(dictionary);

    // A name stands for the field of that name and for the fields below it, as in Acrobat's calculations.
    private IEnumerable<string?> ValuesOfFields(string name) =>
        _fields.Where(f => f.Name == name || f.Name.StartsWith(name + ".", StringComparison.Ordinal)).Select(f => f.Value);

    private static bool SameValue(string? current, string result) =>
        current == result || FormFunctions.ParseNumber(current ?? "") is { } a && FormFunctions.ParseNumber(result) is { } b && a == b;
}
