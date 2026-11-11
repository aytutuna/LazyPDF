// The list of steps and the settings of the one selected.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Tools.Export;
using LazyPDF.App.Tools.Ocr;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Batch;

public partial class BatchPanel
{
    private static readonly PdfALevel[] Levels = Enum.GetValues<PdfALevel>();
    private static readonly int[] Dpis = [72, 96, 150, 300, 600];
    private OcrLanguageState? _languages;

    private static string TitleOf(BatchStepKind kind) => kind switch
    {
        BatchStepKind.Ocr => Loc.T("Make searchable"),
        BatchStepKind.Compress => Loc.T("Make smaller"),
        BatchStepKind.Clean => Loc.T("Clean for sharing"),
        BatchStepKind.Watermark => Loc.T("Watermark"),
        BatchStepKind.Bates => Loc.T("Bates numbers"),
        BatchStepKind.PageNumbers => Loc.T("Page numbers"),
        BatchStepKind.Rotate => Loc.T("Rotate pages"),
        BatchStepKind.Protect => Loc.T("Protect"),
        BatchStepKind.ExportPictures => Loc.T("Export pictures"),
        _ => Loc.T("PDF/A"),
    };

    private static string PresetName(OptimizePreset preset) => preset switch
    {
        OptimizePreset.Small => Loc.T("Small"),
        OptimizePreset.Balanced => Loc.T("Balanced"),
        _ => Loc.T("High quality"),
    };

    private static string DetailOf(BatchStep step) => step.Kind switch
    {
        BatchStepKind.Ocr => Loc.T("Language {0}", step.Text),
        BatchStepKind.Compress => PresetName(step.Preset),
        BatchStepKind.Clean => step.KeepComments || step.KeepForms || step.KeepLinks || step.KeepAttachments
            ? Loc.T("Keeps some private data") : Loc.T("Removes hidden and private data"),
        BatchStepKind.Watermark => step.Text.Length == 0 ? Loc.T("No text yet") : step.Text,
        BatchStepKind.Bates => Loc.T("Starts at {0}", new BatesSpec(step.Text, step.Suffix, step.Digits, step.Start).Format(step.Start)),
        BatchStepKind.PageNumbers => Loc.T("{0}, printed on the pages", step.Text),
        BatchStepKind.Rotate => TurnDetail(step),
        BatchStepKind.Protect => step.Password.Length == 0 ? Loc.T("Password not set") : Loc.T("Password to open the file"),
        BatchStepKind.ExportPictures => Loc.T("{0} at {1} dpi", PictureName(step.Picture), step.Dpi),
        _ => step.Level.Name(),
    };

    private static string PictureName(PictureFormat picture) => picture switch
    {
        PictureFormat.Png => "PNG",
        PictureFormat.Jpeg => "JPEG",
        PictureFormat.Tiff => "TIFF",
        _ => "BMP",
    };

    private static string TurnDetail(BatchStep step)
    {
        string turn = step.Turn switch
        {
            180 => Loc.T("{0} degrees", step.Turn),
            270 => Loc.T("{0} degrees clockwise (90 anticlockwise)", step.Turn),
            _ => Loc.T("{0} degrees clockwise", step.Turn),
        };
        return step.Pages switch
        {
            BatchPages.Odd => turn + Loc.T(", odd pages only"),
            BatchPages.Even => turn + Loc.T(", even pages only"),
            _ => turn,
        };
    }

    private static string AnchorName(StampAnchor anchor) => anchor switch
    {
        StampAnchor.TopLeft => Loc.T("Top left"),
        StampAnchor.Top => Loc.T("Top"),
        StampAnchor.TopRight => Loc.T("Top right"),
        StampAnchor.Left => Loc.T("Left"),
        StampAnchor.Center => Loc.T("Center"),
        StampAnchor.Right => Loc.T("Right"),
        StampAnchor.BottomLeft => Loc.T("Bottom left"),
        StampAnchor.Bottom => Loc.T("Bottom"),
        _ => Loc.T("Bottom right"),
    };

    private static string PlaceName(BatesPlace place) => place switch
    {
        BatesPlace.FooterRight => Loc.T("Footer, right"),
        BatesPlace.FooterCenter => Loc.T("Footer, center"),
        BatesPlace.FooterLeft => Loc.T("Footer, left"),
        BatesPlace.HeaderRight => Loc.T("Header, right"),
        BatesPlace.HeaderCenter => Loc.T("Header, center"),
        _ => Loc.T("Header, left"),
    };

    private void FillChoices()
    {
        foreach (var (turn, text) in new[] { (90, Loc.T("Right (90 degrees)")), (180, Loc.T("Upside down (180 degrees)")), (270, Loc.T("Left (270 degrees)")) })
            TurnBox.Items.Add(new ComboBoxItem { Content = text, Tag = turn });
        foreach (var (pages, text) in new[] { (BatchPages.All, Loc.T("All pages")), (BatchPages.Odd, Loc.T("Odd pages")), (BatchPages.Even, Loc.T("Even pages")) })
            RotatePagesBox.Items.Add(new ComboBoxItem { Content = text, Tag = pages });
        foreach (var picture in Enum.GetValues<PictureFormat>()) PictureBox.Items.Add(new ComboBoxItem { Content = PictureName(picture), Tag = picture });
        foreach (int dpi in Dpis) DpiBox.Items.Add(new ComboBoxItem { Content = $"{dpi} dpi", Tag = dpi });
        foreach (var preset in Enum.GetValues<OptimizePreset>()) PresetBox.Items.Add(new ComboBoxItem { Content = PresetName(preset), Tag = preset });
        foreach (var level in Levels) LevelBox.Items.Add(new ComboBoxItem { Content = level.Name(), Tag = level });
        foreach (var anchor in Enum.GetValues<StampAnchor>()) AnchorBox.Items.Add(new ComboBoxItem { Content = AnchorName(anchor), Tag = anchor });
        foreach (var place in Enum.GetValues<BatesPlace>()) PlaceBox.Items.Add(new ComboBoxItem { Content = PlaceName(place), Tag = place });
    }

    private BatchStep? Selected => (StepList.SelectedItem as StepRow)?.Step;

    private void ShowSteps(BatchStep? select = null)
    {
        ShowRows(select is null ? -1 : _set.Steps.IndexOf(select));
        NoSteps.Visibility = _set.Steps.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowEditor();
        RaiseActionChanged();
    }

    private void ShowEditor()
    {
        var step = Selected;
        int at = StepList.SelectedIndex;
        UpButton.IsEnabled = step is not null && at > 0;
        DownButton.IsEnabled = step is not null && at < _set.Steps.Count - 1;
        RemoveStepButton.IsEnabled = step is not null;
        Editor.Visibility = step is null ? Visibility.Collapsed : Visibility.Visible;
        if (step is null) return;

        CleanEditor.Visibility = Show(step.Kind == BatchStepKind.Clean);
        LanguageEditor.Visibility = Show(step.Kind == BatchStepKind.Ocr);
        PresetEditor.Visibility = Show(step.Kind == BatchStepKind.Compress);
        WatermarkEditor.Visibility = Show(step.Kind == BatchStepKind.Watermark);
        BatesEditor.Visibility = Show(step.Kind == BatchStepKind.Bates);
        PageNumbersEditor.Visibility = Show(step.Kind == BatchStepKind.PageNumbers);
        PlaceEditor.Visibility = Show(step.Kind is BatchStepKind.Bates or BatchStepKind.PageNumbers);
        LevelEditor.Visibility = Show(step.Kind == BatchStepKind.PdfA);
        RotateEditor.Visibility = Show(step.Kind == BatchStepKind.Rotate);
        ProtectEditor.Visibility = Show(step.Kind == BatchStepKind.Protect);
        PicturesEditor.Visibility = Show(step.Kind == BatchStepKind.ExportPictures);
        QualityRow.Visibility = Show(step.Picture == PictureFormat.Jpeg);

        _loading = true;
        if (step.Kind == BatchStepKind.Ocr) ShowLanguages(step);
        PresetBox.SelectedIndex = (int)step.Preset;
        KeepComments.IsChecked = step.KeepComments;
        KeepForms.IsChecked = step.KeepForms;
        KeepLinks.IsChecked = step.KeepLinks;
        KeepAttachments.IsChecked = step.KeepAttachments;
        WatermarkBox.Text = step.Text;
        OpacityBox.Text = step.Opacity.ToString(CultureInfo.CurrentCulture);
        AngleBox.Text = step.Angle.ToString(CultureInfo.CurrentCulture);
        SizeBox.Text = step.Size.ToString(CultureInfo.CurrentCulture);
        AnchorBox.SelectedIndex = (int)step.Anchor;
        PageTextBox.Text = step.Text;
        PageSizeBox.Text = step.FontSize.ToString(CultureInfo.CurrentCulture);
        PrefixBox.Text = step.Text;
        SuffixBox.Text = step.Suffix;
        PlaceBox.SelectedIndex = (int)step.Place;
        DigitsBox.Text = step.Digits.ToString(CultureInfo.CurrentCulture);
        StartBox.Text = step.Start.ToString(CultureInfo.CurrentCulture);
        LevelBox.SelectedIndex = Array.IndexOf(Levels, step.Level);
        TurnBox.SelectedIndex = step.Turn / 90 - 1;
        RotatePagesBox.SelectedIndex = (int)step.Pages;
        ProtectBox.Password = step.Password;
        PictureBox.SelectedIndex = (int)step.Picture;
        DpiBox.SelectedIndex = Array.IndexOf(Dpis, step.Dpi);
        QualityBox.Value = step.Quality;
        _loading = false;
    }

    // A language the set names but Windows lacks stays in the list, so the step shows what it will ask for.
    private void ShowLanguages(BatchStep step)
    {
        _languages ??= OcrLanguageState.Read();
        var choices = _languages.Installed.ToList();
        var chosen = choices.FirstOrDefault(l => string.Equals(l.Tag, step.Text, StringComparison.OrdinalIgnoreCase));
        if (chosen is null)
        {
            chosen = new OcrLanguage(step.Text, step.Text);
            choices.Add(chosen);
        }
        LanguageBox.ItemsSource = choices;
        LanguageBox.SelectedItem = chosen;
        LanguageNote.Text = _languages.Advice;
    }

    private static bool Number(TextBox box, int low, int high, out int value)
    {
        bool ok = int.TryParse(box.Text, CultureInfo.CurrentCulture, out value);
        value = Math.Clamp(value, low, high);
        return ok;
    }

    private static Visibility Show(bool on) => on ? Visibility.Visible : Visibility.Collapsed;

    private void StepList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading) ShowEditor();
    }

    private void AddStep_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = AddStepButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        foreach (var kind in Enum.GetValues<BatchStepKind>())
        {
            var item = new MenuItem { Header = TitleOf(kind) };
            System.Windows.Automation.AutomationProperties.SetName(item, TitleOf(kind));
            item.Click += (_, _) =>
            {
                if (_set.Steps.Any(s => s.Kind == BatchStepKind.Protect))
                {
                    Host?.ShowProblem(BatchRunner.ProtectNotLast());
                    return;
                }
                if (_set.Steps.Any(s => s.Kind == BatchStepKind.ExportPictures))
                {
                    Host?.ShowProblem(BatchRunner.ExportNotLast());
                    return;
                }
                var step = BatchStep.Of(kind);
                _set.Steps.Add(step);
                ShowSteps(step);
            };
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    private void Up_Click(object sender, RoutedEventArgs e) => Move(-1);

    private void Down_Click(object sender, RoutedEventArgs e) => Move(1);

    private void Move(int by)
    {
        if (Selected is not { } step) return;
        int to = _set.Steps.IndexOf(step) + by;
        if (to < 0 || to >= _set.Steps.Count) return;
        var moved = _set.Steps.ToList();
        moved.Remove(step);
        moved.Insert(to, step);
        if (moved.FindIndex(s => s.Kind == BatchStepKind.Protect) is >= 0 and var protect && protect < moved.Count - 1)
        {
            Host?.ShowProblem(BatchRunner.ProtectNotLast());
            return;
        }
        if (moved.FindIndex(s => s.Kind == BatchStepKind.ExportPictures) is >= 0 and var export && export < moved.Count - 1)
        {
            Host?.ShowProblem(BatchRunner.ExportNotLast());
            return;
        }
        _set.Steps = moved;
        ShowSteps(step);
    }

    private void RemoveStep_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } step) return;
        _set.Steps.Remove(step);
        ShowSteps();
        RecheckWatch();
    }

    // One handler for the boxes of every kind: only the ones of the selected kind are on screen.
    private void Setting_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading || Selected is not { } step) return;
        switch (step.Kind)
        {
            case BatchStepKind.Ocr when LanguageBox.SelectedItem is OcrLanguage language:
                step.Text = language.Tag;
                break;
            case BatchStepKind.Clean:
                step.KeepComments = KeepComments.IsChecked == true;
                step.KeepForms = KeepForms.IsChecked == true;
                step.KeepLinks = KeepLinks.IsChecked == true;
                step.KeepAttachments = KeepAttachments.IsChecked == true;
                break;
            case BatchStepKind.Compress when PresetBox.SelectedItem is ComboBoxItem { Tag: OptimizePreset preset }:
                step.Preset = preset;
                break;
            case BatchStepKind.Watermark:
                step.Text = WatermarkBox.Text;
                if (Number(OpacityBox, 5, 100, out int opacity)) step.Opacity = opacity;
                if (Number(AngleBox, -360, 360, out int angle)) step.Angle = angle;
                if (Number(SizeBox, 10, 100, out int size)) step.Size = size;
                if (AnchorBox.SelectedItem is ComboBoxItem { Tag: StampAnchor anchor }) step.Anchor = anchor;
                break;
            case BatchStepKind.Bates:
                step.Text = PrefixBox.Text;
                step.Suffix = SuffixBox.Text;
                if (PlaceBox.SelectedItem is ComboBoxItem { Tag: BatesPlace place }) step.Place = place;
                if (int.TryParse(DigitsBox.Text, CultureInfo.CurrentCulture, out int digits)) step.Digits = Math.Clamp(digits, 1, 18);
                if (long.TryParse(StartBox.Text, CultureInfo.CurrentCulture, out long start) && start >= 0) step.Start = start;
                break;
            case BatchStepKind.PageNumbers:
                step.Text = PageTextBox.Text;
                if (Number(PageSizeBox, 6, 48, out int fontSize)) step.FontSize = fontSize;
                if (PlaceBox.SelectedItem is ComboBoxItem { Tag: BatesPlace pagePlace }) step.Place = pagePlace;
                break;
            case BatchStepKind.Rotate:
                if (TurnBox.SelectedItem is ComboBoxItem { Tag: int turn }) step.Turn = turn;
                if (RotatePagesBox.SelectedItem is ComboBoxItem { Tag: BatchPages pages }) step.Pages = pages;
                break;
            case BatchStepKind.Protect:
                step.Password = ProtectBox.Password;
                break;
            case BatchStepKind.ExportPictures:
                if (PictureBox.SelectedItem is ComboBoxItem { Tag: PictureFormat picture }) step.Picture = picture;
                if (DpiBox.SelectedItem is ComboBoxItem { Tag: int dpi }) step.Dpi = dpi;
                step.Quality = (int)QualityBox.Value;
                QualityRow.Visibility = Show(step.Picture == PictureFormat.Jpeg);
                break;
            case BatchStepKind.PdfA when LevelBox.SelectedItem is ComboBoxItem { Tag: PdfALevel level }:
                step.Level = level;
                break;
        }
        ShowRows(StepList.SelectedIndex);
    }

    private void ShowRows(int selected)
    {
        _loading = true;
        StepList.ItemsSource = _set.Steps.Select(s => new StepRow(s, TitleOf(s.Kind), DetailOf(s))).ToList();
        StepList.SelectedIndex = selected;
        _loading = false;
    }
}
