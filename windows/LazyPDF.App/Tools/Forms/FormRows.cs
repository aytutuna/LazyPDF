using LazyPDF.Core;

namespace LazyPDF.App.Tools.Forms;

/// <summary>A field in the list: where it is and what kind it is. The ordinal tells apart fields that share a name.</summary>
internal sealed record FieldRow(string Name, string Detail, int Page, int Index, int Ordinal)
{
    public string Summary => Name + ", " + Detail;
}

/// <summary>A field the detector found, with the box that adds it.</summary>
internal sealed class FoundRow(FieldProposal proposal)
{
    public FieldProposal Proposal { get; } = proposal;

    public bool IsChecked { get; set; } = true;

    public string Text { get; } = Loc.T("{0}, page {1}", proposal.Name, proposal.PageIndex + 1);
}

internal sealed record KindChoice(string Text, FieldKind? Kind);

internal sealed record TabChoice(string Text, TabOrder Order);
