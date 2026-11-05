using System.Windows;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Sanitize;

/// <summary>One thing the scan found. Some can be switched off; the rest are always removed or only reported.</summary>
public sealed class SanitizeRow(SanitizeFinding finding)
{
    public SanitizeItem Item { get; } = finding.Item;

    public int Count { get; } = finding.Count;

    public string Label => Loc.T("{0} ({1})", OptimizeText.ItemName(Item), Count);

    public bool CanTick => Item is not (SanitizeItem.HiddenText or SanitizeItem.PreviousVersions or SanitizeItem.Signatures);

    /// <summary>Hidden text is only reported, and invisible text may be a scan's text layer, so it starts off.</summary>
    public bool IsChecked { get; set; } = finding.Item is not (SanitizeItem.HiddenText or SanitizeItem.InvisibleText);

    public string Note => Item switch
    {
        SanitizeItem.HiddenText => Loc.T("Only reported. Redact removes it."),
        SanitizeItem.InvisibleText => Loc.T("May be the text layer of a scan. Off unless you tick it."),
        SanitizeItem.PreviousVersions or SanitizeItem.Signatures => Loc.T("Always removed."),
        _ => "",
    };

    public Visibility NoteVisibility => Note.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
}
