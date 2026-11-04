// The form's fields as one draft. A field that cannot be read gives no draft and a sentence for the user.

using System.Globalization;
using LazyPDF.Core;
using FontStyles = LazyPDF.Core.FontStyles;

namespace LazyPDF.App.Tools.Stamps;

public sealed partial class StampsPanel
{
    private StampMode Mode => (StampMode)KindBox.SelectedIndex;

    private StampDraft? ReadDraft(out string? problem)
    {
        problem = null;
        int count = Tab!.PageCount;
        var (pages, error) = PageChoice.Resolve((PageSet)PagesBox.SelectedIndex, PagesText.Text, count);
        if (error is not null)
        {
            problem = error;
            return null;
        }
        if (PageChoice.Targets(pages, count).Count == 0)
        {
            problem = Loc.T("No page in this file matches.");
            return null;
        }

        var style = (BoldBox.IsChecked == true ? FontStyles.Bold : FontStyles.Regular) | (ItalicBox.IsChecked == true ? FontStyles.Italic : FontStyles.Regular);
        string family = _families[Math.Max(0, FontFamilyBox.SelectedIndex)];
        var color = _colors[Math.Max(0, ColorBox.SelectedIndex)].Color;
        double opacity = OpacitySlider.Value / 100;
        string? layer = LayerBox.IsChecked == true ? (Mode == StampMode.Watermark ? Loc.T("Watermark") : Loc.T("Background")) : null;
        StampDraft draft;
        switch (Mode)
        {
            case StampMode.Watermark:
                draft = new StampDraft(Watermark: new WatermarkSpec
                {
                    Text = WatermarkText.Text,
                    FontFamily = family,
                    FontStyle = style,
                    Color = color,
                    Opacity = opacity,
                    Rotation = TurnSlider.Value,
                    Scale = ScaleSlider.Value / 100,
                    Anchor = (StampAnchor)PlaceBox.SelectedIndex,
                    Behind = BehindBox.IsChecked == true,
                    LayerName = layer,
                    Pages = pages,
                }, Picture: _picture);
                break;
            case StampMode.Background:
                draft = new StampDraft(Background: new BackgroundSpec
                {
                    Color = _backColors[Math.Max(0, BackColorBox.SelectedIndex)].Color,
                    Fit = (BackgroundFit)FitBox.SelectedIndex,
                    Opacity = opacity,
                    LayerName = layer,
                    Pages = pages,
                }, Picture: _picture);
                break;
            default:
                var spec = Mode == StampMode.HeaderFooter ? BandsSpec(ref problem) : BatesSpec(ref problem);
                if (spec is null) return null;
                draft = new StampDraft(HeaderFooter: spec with
                {
                    FontFamily = family,
                    FontStyle = style,
                    Color = color,
                    FontSize = TextSizeSlider.Value,
                    MarginX = MarginSlider.Value,
                    MarginTop = MarginSlider.Value,
                    MarginBottom = MarginSlider.Value,
                    FileName = Tab.Title,
                    Date = DateTimeOffset.Now,
                    Culture = CultureInfo.CurrentCulture,
                    Pages = pages,
                });
                break;
        }
        problem = draft.Problem;
        return problem is null ? draft : null;
    }

    private HeaderFooterSpec? BandsSpec(ref string? problem)
    {
        if (!int.TryParse(FirstNumber.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out int first))
        {
            problem = Loc.T("The first page number must be a whole number.");
            return null;
        }
        return new HeaderFooterSpec
        {
            Header = new HeaderFooterBand(HeaderLeft.Text, HeaderCentre.Text, HeaderRight.Text),
            Footer = new HeaderFooterBand(FooterLeft.Text, FooterCentre.Text, FooterRight.Text),
            StartNumber = first,
            DateFormat = string.IsNullOrEmpty(DateFormatBox.Text) ? "yyyy-MM-dd" : DateFormatBox.Text,
        };
    }

    private HeaderFooterSpec? BatesSpec(ref string? problem)
    {
        if (!int.TryParse(DigitsBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out int digits) || digits is < 1 or > 18)
        {
            problem = Loc.T("Digits must be a number from 1 to 18.");
            return null;
        }
        if (StartBox.Text.Length == 0)
        {
            problem = Loc.T("Type the first number of the run.");
            return null;
        }
        if (!long.TryParse(StartBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out long start) || start < 0)
        {
            problem = Loc.T("The first number must be 0 or more.");
            return null;
        }
        const string Slot = "{bates}";
        int place = BatesPlaceBox.SelectedIndex;
        var band = new HeaderFooterBand(place % 3 == 0 ? Slot : "", place % 3 == 1 ? Slot : "", place % 3 == 2 ? Slot : "");
        var empty = new HeaderFooterBand();
        return new HeaderFooterSpec
        {
            Header = place < 3 ? band : empty,
            Footer = place < 3 ? empty : band,
            Bates = new BatesSpec(PrefixBox.Text, SuffixBox.Text, digits, start),
        };
    }
}
