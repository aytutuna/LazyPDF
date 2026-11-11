// From Lazy Print's InfoButton.cs.
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace LazyPDF.App;

/// <summary>
/// The ⓘ next to a label: a focusable button that opens a small flyout (a WPF Popup styled as a
/// Fluent flyout) with a procedure or keyboard help. The flyout takes keyboard focus, closes with
/// Esc or a click elsewhere, and gives the focus back to the button. Screen readers hear the button
/// as "More about {Label}" and the flyout's whole text when it opens.
/// </summary>
public sealed class InfoButton : Button
{
    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
        nameof(Label), typeof(string), typeof(InfoButton), new PropertyMetadata("", (d, _) => ((InfoButton)d).Rename()));

    public static readonly DependencyProperty HeadingProperty = DependencyProperty.Register(
        nameof(Heading), typeof(string), typeof(InfoButton), new PropertyMetadata(null, (d, _) => ((InfoButton)d).Fill()));

    public static readonly DependencyProperty InfoTextProperty = DependencyProperty.Register(
        nameof(InfoText), typeof(string), typeof(InfoButton), new PropertyMetadata("", (d, _) => ((InfoButton)d).Fill()));

    private readonly Popup _popup;
    private readonly InfoFlyoutPanel _panel;
    private readonly TextBlock _heading;
    private readonly TextBlock _text;
    /// <summary>When the flyout last closed: a click on the button that closed it must not open it again.</summary>
    private DateTime _closedAt;

    public InfoButton()
    {
        SetResourceReference(StyleProperty, "SmallIconButtonStyle");
        Content = "\uE946";
        Width = 28;
        Height = 28;
        FontSize = 13;
        VerticalAlignment = VerticalAlignment.Center;
        ToolTipService.SetShowsToolTipOnKeyboardFocus(this, true);

        _heading = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 6) };
        _heading.SetResourceReference(StyleProperty, "BodyStrongText");
        _text = new TextBlock { TextWrapping = TextWrapping.Wrap };
        _text.SetResourceReference(StyleProperty, "BodyText");
        var stack = new StackPanel();
        stack.Children.Add(_heading);
        stack.Children.Add(_text);
        _panel = new InfoFlyoutPanel
        {
            Child = stack,
            MaxWidth = 320,
            Padding = new Thickness(14, 10, 14, 12),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Margin = new Thickness(8, 4, 8, 12),
            Focusable = true,
            FocusVisualStyle = null,
        };
        _panel.SetResourceReference(Border.BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
        _panel.SetResourceReference(Border.BorderBrushProperty, "SurfaceStrokeColorDefaultBrush");
        _panel.SetResourceReference(EffectProperty, "CardHoverShadow");
        _panel.SetResourceReference(TextElement.FontFamilyProperty, "TextFontFamily");
        _panel.SetResourceReference(TextElement.ForegroundProperty, "TextFillColorPrimaryBrush");
        _panel.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            Close();
        };
        _popup = new Popup
        {
            Child = _panel,
            StaysOpen = false,
            AllowsTransparency = true,
            Placement = PlacementMode.Bottom,
            PlacementTarget = this,
            HorizontalOffset = -12,
        };
        _popup.Opened += (_, _) =>
            Dispatcher.InvokeAsync(() =>
            {
                _panel.Focus();
                Keyboard.Focus(_panel);
            }, System.Windows.Threading.DispatcherPriority.Input);
        _popup.Closed += (_, _) =>
        {
            _closedAt = DateTime.UtcNow;
            if (_panel.IsKeyboardFocusWithin || Keyboard.FocusedElement is null) Focus();
        };
        Click += (_, _) =>
        {
            if (_popup.IsOpen) Close();
            else if ((DateTime.UtcNow - _closedAt).TotalMilliseconds > 250) _popup.IsOpen = true;
        };
        Rename();
        Fill();
    }

    /// <summary>The label the ⓘ is next to: the button is named "More about {Label}".</summary>
    public string Label
    {
        get => (string)GetValue(LabelProperty);
        set => SetValue(LabelProperty, value);
    }

    /// <summary>The flyout's bold first line ("How it works", "Keyboard"); none when null.</summary>
    public string? Heading
    {
        get => (string?)GetValue(HeadingProperty);
        set => SetValue(HeadingProperty, value);
    }

    /// <summary>What the flyout says; numbered steps go one per line.</summary>
    public string InfoText
    {
        get => (string)GetValue(InfoTextProperty);
        set => SetValue(InfoTextProperty, value);
    }

    /// <summary>Whether the flyout is open (harnesses and tests read it).</summary>
    public bool IsOpen => _popup.IsOpen;

    /// <summary>Opens the flyout (as a click does).</summary>
    public void Open() => _popup.IsOpen = true;

    /// <summary>Closes the flyout and gives the keyboard focus back to the button.</summary>
    public void Close()
    {
        bool hadFocus = _panel.IsKeyboardFocusWithin;
        _popup.IsOpen = false;
        if (hadFocus) Focus();
    }

    /// <summary>The flyout's content, for screen readers and checks.</summary>
    internal FrameworkElement Flyout => _panel;

    private void Rename()
    {
        string name = string.IsNullOrEmpty(Label) ? Loc.T("More information") : Loc.T("More about {0}", Label);
        AutomationProperties.SetName(this, name);
        ToolTip = name;
    }

    private void Fill()
    {
        _heading.Text = Heading ?? "";
        _heading.Visibility = string.IsNullOrEmpty(Heading) ? Visibility.Collapsed : Visibility.Visible;
        _text.Text = InfoText;
        AutomationProperties.SetName(_panel, string.IsNullOrEmpty(Heading) ? InfoText : $"{Heading}. {InfoText}");
        AutomationProperties.SetHelpText(this, InfoText);
    }
}

/// <summary>The flyout's surface: a group that screen readers name with its whole text when it takes focus.</summary>
internal sealed class InfoFlyoutPanel : Border
{
    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    private sealed class Peer(InfoFlyoutPanel owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;

        protected override string GetClassNameCore() => nameof(InfoFlyoutPanel);

        protected override bool IsKeyboardFocusableCore() => true;
    }
}
