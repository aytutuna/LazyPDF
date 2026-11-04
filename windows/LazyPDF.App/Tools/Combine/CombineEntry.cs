using System.ComponentModel;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Combine;

/// <summary>A file in the list to combine. <see cref="Document"/> is null for the open document, which is read again when the work starts.</summary>
public sealed class CombineEntry(string name, int pages, PdfDocument? document) : INotifyPropertyChanged
{
    private int _pages = pages;
    private string _range = "";

    public string Name { get; } = name;

    public PdfDocument? Document { get; } = document;

    /// <summary>Pages to take, as typed ("1-3, 5"); empty takes all.</summary>
    public string Range
    {
        get => _range;
        set
        {
            _range = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Range)));
        }
    }

    public int Pages
    {
        get => _pages;
        set
        {
            _pages = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Detail)));
        }
    }

    public string Detail => Loc.Plural(Pages, "{0} page", "{0} pages", Pages);

    public string RangeName => Loc.T("Pages of {0}", Name);

    public event PropertyChangedEventHandler? PropertyChanged;
}
