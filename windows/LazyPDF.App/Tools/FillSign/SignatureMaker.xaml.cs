using System.Windows;
using System.Windows.Controls;
using System.Windows.Ink;
using System.Windows.Media;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.FillSign;

/// <summary>Makes a signature or initials by typing, drawing or choosing a picture, and hands the image back.</summary>
public partial class SignatureMaker : UserControl
{
    // Handwriting faces Windows ships, tried in this order; the plain face is there so the list is never empty.
    private static readonly string[] Faces = ["Segoe Script", "Ink Free", "Lucida Handwriting", "Segoe Print", "Brush Script MT", "Mistral", "Freestyle Script", "Segoe UI"];

    private PdfRgbaImage? _picture;

    public SignatureMaker()
    {
        InitializeComponent();
        var installed = System.Windows.Media.Fonts.SystemFontFamilies.SelectMany(f => f.FamilyNames.Values).ToHashSet(StringComparer.OrdinalIgnoreCase);
        FontBox.ItemsSource = Faces.Where(installed.Contains).ToList();
        FontBox.SelectedIndex = 0;
    }

    /// <summary>The image made so far; null until there is something to use.</summary>
    public PdfRgbaImage? Image { get; private set; }

    public bool Keep => KeepBox.IsChecked == true;

    public event EventHandler? Made;

    public event EventHandler? Cancelled;

    /// <summary>Starts over with an empty page.</summary>
    public void Reset()
    {
        NameBox.Text = "";
        Ink.Strokes.Clear();
        InkColourBox.SelectedIndex = 0;
        _picture = null;
        TurnButton.IsEnabled = false;
        PictureNote.Text = Loc.T("Sign on white paper and take a photo. The paper is made see-through.");
        TypeMode.IsChecked = true;
        Show(null);
    }

    private void Show(PdfRgbaImage? image)
    {
        Image = image;
        Preview.Source = image is null ? null : SignatureArt.ToBitmap(image);
        UseButton.IsEnabled = image is not null;
    }

    private void Rebuild()
    {
        if (!IsInitialized) return;
        var colour = InkColour();
        Ink.DefaultDrawingAttributes.Color = colour;
        Show(TypeMode.IsChecked == true ? SignatureArt.Typed(NameBox.Text, FontBox.SelectedItem as string ?? "Segoe UI", colour)
            : DrawMode.IsChecked == true ? SignatureArt.Drawn(Ink.Strokes, colour)
            : _picture);
    }

    private Color InkColour() => InkColourBox.SelectedIndex switch { 1 => Colors.Blue, 2 => Colors.Red, _ => Colors.Black };

    private void Mode_Checked(object sender, RoutedEventArgs e)
    {
        if (!IsInitialized) return;
        TypePage.Visibility = TypeMode.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        DrawPage.Visibility = DrawMode.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        PicturePage.Visibility = PictureMode.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        InkRow.Visibility = PictureMode.IsChecked == true ? Visibility.Collapsed : Visibility.Visible;
        Rebuild();
    }

    private void NameBox_TextChanged(object sender, TextChangedEventArgs e) => Rebuild();

    private void FontBox_SelectionChanged(object sender, SelectionChangedEventArgs e) => Rebuild();

    private void InkColourBox_SelectionChanged(object sender, SelectionChangedEventArgs e) => Rebuild();

    private void Ink_StrokeCollected(object sender, InkCanvasStrokeCollectedEventArgs e) => Rebuild();

    private void Ink_StrokeErasing(object sender, InkCanvasStrokeErasingEventArgs e) => Dispatcher.BeginInvoke(Rebuild);

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        Ink.Strokes.Clear();
        Rebuild();
    }

    private void Choose_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = Loc.T("Choose a picture"), Filter = Loc.T("Pictures") + "|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff" };
        if (dialog.ShowDialog() != true) return;
        try
        {
            _picture = SignatureArt.FromFile(File.ReadAllBytes(dialog.FileName));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            _picture = null;
        }
        TurnButton.IsEnabled = _picture is not null;
        PictureNote.Text = _picture is null ? Loc.T("That file is not a picture Lazy PDF can read. Choose a PNG or JPEG.") : System.IO.Path.GetFileName(dialog.FileName);
        Rebuild();
    }

    private void Turn_Click(object sender, RoutedEventArgs e)
    {
        if (_picture is null) return;
        _picture = SignatureArt.Turn(_picture);
        Rebuild();
    }

    private void Use_Click(object sender, RoutedEventArgs e) => Made?.Invoke(this, EventArgs.Empty);

    private void Cancel_Click(object sender, RoutedEventArgs e) => Cancelled?.Invoke(this, EventArgs.Empty);
}
