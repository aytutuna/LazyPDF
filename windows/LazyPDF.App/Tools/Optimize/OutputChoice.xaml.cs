using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;

namespace LazyPDF.App.Tools.Optimize;

/// <summary>New tab or the same file, under the tools that rewrite the whole file.</summary>
public sealed partial class OutputChoice : UserControl
{
    private bool _signed;

    public OutputChoice()
    {
        InitializeComponent();
        ShowNote();
    }

    /// <summary>True when the result takes the place of the file on disk.</summary>
    public bool Replace => ThisFile.IsChecked == true;

    /// <param name="removesSignatures">Whether the tool strips signatures from the result; if not, they stay in it but no longer check out.</param>
    public void Configure(DocumentTab tab, bool removesSignatures)
    {
        bool signed = tab.Document.IsSigned;
        _signed = signed;
        ThisFile.IsEnabled = tab.Path is not null && !signed;
        if (!ThisFile.IsEnabled) NewFile.IsChecked = true;
        SignedRow.Visibility = signed ? Visibility.Visible : Visibility.Collapsed;
        SignedNote.Text = removesSignatures
            ? Loc.T("Signatures are removed from the result.")
            : Loc.T("Signatures stay in the result but are no longer valid.");
        ShowNote();
    }

    private void Choice_Checked(object sender, RoutedEventArgs e) => ShowNote();

    private void ShowNote()
    {
        if (Note is null) return;
        Note.Text = _signed ? Loc.T("A signed file is not replaced. The result opens in a new tab.")
            : !ThisFile.IsEnabled ? Loc.T("This file is not saved yet.")
            : Replace ? Loc.T("Replaces the file on disk and clears Undo.")
            : Loc.T("Opens in a new tab. You name it when you save.");
    }
}
