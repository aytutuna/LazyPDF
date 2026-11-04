// A run picked in the list goes back into the form: all of it when this session wrote it, what the file keeps otherwise.

using LazyPDF.Core;
using FontStyles = LazyPDF.Core.FontStyles;

namespace LazyPDF.App.Tools.Stamps;

public sealed partial class StampsPanel
{
    private void Load(StampInfo info)
    {
        _ready = false;
        KindBox.SelectedIndex = (int)(info.Kind switch
        {
            StampKind.Background => StampMode.Background,
            StampKind.HeaderFooter => StampMode.HeaderFooter,
            StampKind.Bates => StampMode.Bates,
            _ => StampMode.Watermark,
        });
        if (_written.TryGetValue((Tab!.Id, info.Id), out var draft) && draft.Kind == info.Kind) Fill(draft);
        else FromFile(info);

        if (info.Pages.Count == Tab.PageCount)
        {
            PagesBox.SelectedIndex = (int)PageSet.All;
        }
        else
        {
            PagesBox.SelectedIndex = (int)PageSet.Typed;
            PagesText.Text = PageChoice.Describe(info.Pages);
        }
        ShowMode();
        _ready = true;
    }

    // The file keeps a run's kind, a label and its pages. What it does not keep is left empty, so the update asks for it again.
    private void FromFile(StampInfo info)
    {
        SetPicture(null);
        switch (info.Kind)
        {
            case StampKind.Watermark:
                WatermarkText.Text = info.Label is "image" ? "" : info.Label ?? "";
                BehindBox.IsChecked = info.Behind;
                break;
            case StampKind.HeaderFooter:
                foreach (var box in new[] { HeaderLeft, HeaderCentre, HeaderRight, FooterLeft, FooterCentre, FooterRight }) box.Text = "";
                break;
            case StampKind.Bates:
                StartBox.Text = "";
                break;
        }
    }

    private void Fill(StampDraft draft)
    {
        SetPicture(draft.Picture);
        if (draft.Watermark is { } mark)
        {
            WatermarkText.Text = mark.Text ?? "";
            Look(mark.FontFamily, mark.FontStyle, mark.Color);
            OpacitySlider.Value = mark.Opacity * 100;
            TurnSlider.Value = mark.Rotation;
            ScaleSlider.Value = mark.Scale * 100;
            PlaceBox.SelectedIndex = (int)mark.Anchor;
            BehindBox.IsChecked = mark.Behind;
            LayerBox.IsChecked = mark.LayerName is not null;
        }
        else if (draft.Background is { } back)
        {
            BackColorBox.SelectedIndex = Math.Max(0, Array.FindIndex(_backColors, c => c.Color == back.Color));
            FitBox.SelectedIndex = (int)back.Fit;
            OpacitySlider.Value = back.Opacity * 100;
            LayerBox.IsChecked = back.LayerName is not null;
        }
        else
        {
            var spec = draft.HeaderFooter!;
            Look(spec.FontFamily, spec.FontStyle, spec.Color);
            TextSizeSlider.Value = spec.FontSize;
            MarginSlider.Value = spec.MarginX;
            if (spec.Bates is { } bates)
            {
                PrefixBox.Text = bates.Prefix;
                SuffixBox.Text = bates.Suffix;
                DigitsBox.Text = bates.Digits.ToString();
                StartBox.Text = bates.Start.ToString();
                bool header = spec.Header != new HeaderFooterBand();
                var band = header ? spec.Header : spec.Footer;
                BatesPlaceBox.SelectedIndex = (header ? 0 : 3) + (band.Left.Length > 0 ? 0 : band.Center.Length > 0 ? 1 : 2);
            }
            else
            {
                (HeaderLeft.Text, HeaderCentre.Text, HeaderRight.Text) = (spec.Header.Left, spec.Header.Center, spec.Header.Right);
                (FooterLeft.Text, FooterCentre.Text, FooterRight.Text) = (spec.Footer.Left, spec.Footer.Center, spec.Footer.Right);
                FirstNumber.Text = spec.StartNumber.ToString();
                DateFormatBox.Text = spec.DateFormat;
            }
        }
    }

    private void Look(string family, FontStyles style, StampColor color)
    {
        FontFamilyBox.SelectedIndex = Math.Max(0, Array.IndexOf(_families, family));
        BoldBox.IsChecked = style.HasFlag(FontStyles.Bold);
        ItalicBox.IsChecked = style.HasFlag(FontStyles.Italic);
        ColorBox.SelectedIndex = Math.Max(0, Array.FindIndex(_colors, c => c.Color == color));
    }

    private void SetPicture(byte[]? bytes)
    {
        _picture = bytes;
        _pictureImage = bytes is null ? null : Decode(bytes);
        PictureName.Text = Loc.T("Picture");
        ShowPicture();
    }
}
