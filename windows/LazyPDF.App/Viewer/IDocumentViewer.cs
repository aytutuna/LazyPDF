using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>Which tool the pointer is, when no <see cref="IDocumentViewer.PointerTool"/> has taken it.</summary>
public enum PointerMode
{
    /// <summary>Dragging pans the page.</summary>
    Hand,

    /// <summary>Dragging selects text; double and triple clicks select a word and a line.</summary>
    Select,
}

/// <summary>A point of page space on one page.</summary>
public readonly record struct PagePoint(int Page, Point Point);

/// <summary>
/// What a pointer tool is told. <paramref name="Point"/> is in page space of <paramref name="Page"/> (points from the
/// top left of the page as shown, y down) and may lie outside the page during a drag; <paramref name="View"/> is the
/// same place in the viewer's element.
/// </summary>
/// <param name="Pressed">The left button is down.</param>
/// <param name="Clicks">1, 2 or 3 for a press; 0 for a move.</param>
public sealed record PagePointer(int Page, Point Point, Point View, bool Pressed, int Clicks, ModifierKeys Modifiers);

/// <summary>
/// A tool that takes the pointer. Set it as <see cref="IDocumentViewer.PointerTool"/>; the viewer then sends it the
/// left button on the pages instead of panning or selecting. A press, then moves with <see cref="PagePointer.Pressed"/>
/// set to the same page, then a release; the mouse is captured meanwhile so the release always arrives. Moves with
/// no button down arrive for the page under the pointer. The right button, the wheel and the keyboard stay with the viewer.
/// </summary>
public interface IPagePointerTool
{
    /// <summary>The cursor over the pages; null for the arrow.</summary>
    Cursor? Cursor { get; }

    void Press(PagePointer pointer);

    void Move(PagePointer pointer);

    void Release(PagePointer pointer);

    /// <summary>Escape was pressed during a press, or the tool was replaced: drop what was started.</summary>
    void Cancel();
}

/// <summary>A selected stretch of one page: its characters, their text and their boxes in PDF user space (what annotations take as quad points).</summary>
public sealed record SelectedRun(int Page, TextRange Range, string Text, IReadOnlyList<TextQuad> Quads);

/// <summary>
/// What the shell and the tool panels need of the viewer in the stage. <see cref="View"/> is the element the shell puts
/// into the stage; everything else is how code drives it. Page numbers are 0-based. Angles are clockwise degrees.
/// Everything is for the UI thread. Where a method says <i>page space</i> it means points from the top left of the page
/// as shown (crop box, /Rotate applied, before the viewer's own rotation), y down: the engine's display space, which
/// <c>PageGeometry</c> converts to and from PDF user space.
/// </summary>
public interface IDocumentViewer
{
    /// <summary>The element that fills the stage.</summary>
    FrameworkElement View { get; }

    /// <summary>The document shown; null on the Home tab.</summary>
    DocumentTab? Tab { get; }

    /// <summary>Shows <paramref name="tab"/> at the page and zoom the tab remembers (<see cref="DocumentTab.PageIndex"/>, <see cref="DocumentTab.Zoom"/>).</summary>
    void Show(DocumentTab? tab);

    /// <summary>The page in view, 0-based. Setting it scrolls there and notes the jump in the history. The viewer keeps <see cref="DocumentTab.PageIndex"/> current.</summary>
    int PageIndex { get; set; }

    /// <summary>1 is 100 % (the page at the size it prints). Setting it keeps the centre of the view where it is. The viewer keeps <see cref="DocumentTab.Zoom"/> current.</summary>
    double Zoom { get; set; }

    /// <summary>Raised when the page in view or the zoom changed, so the status bar follows.</summary>
    event EventHandler? StateChanged;

    // ----- Looking

    int PageCount { get; }

    /// <summary>The label of a page as the file numbers them ("iv", "A-3"), else its number from 1.</summary>
    string PageLabel(int page);

    /// <summary>The way the zoom follows the window: fit width, fit page, or none once a zoom was chosen.</summary>
    FitMode Fit { get; set; }

    /// <summary>1 for one page across, 2 for facing pages.</summary>
    int Columns { get; set; }

    /// <summary>With two columns, the first page stands alone so that pages 2 and 3 face each other.</summary>
    bool CoverPage { get; set; }

    /// <summary>All pages scroll together; false shows one page or spread at a time.</summary>
    bool Continuous { get; set; }

    /// <summary>0, 90, 180 or 270. Turns the view only; the file is not touched.</summary>
    int Rotation { get; set; }

    /// <summary>Dark or sepia pages for reading; the file is not touched.</summary>
    PageTint Tint { get; set; }

    /// <summary>Hides the viewer's own bar and fits the width, for reading.</summary>
    bool ReadingMode { get; set; }

    /// <summary>The viewer fills the screen in a window of its own.</summary>
    bool FullScreen { get; set; }

    // ----- Going places

    void GoToPage(int page);

    /// <summary>Goes to a destination of the file and notes the jump in the history.</summary>
    void GoToDestination(PdfDestination destination);

    /// <summary>Does what a link or bookmark says: a destination, a named action, or (after asking) an address.</summary>
    void FollowAction(PdfAction? action);

    bool CanGoBack { get; }

    bool CanGoForward { get; }

    void GoBack();

    void GoForward();

    /// <summary>Scrolls so that <paramref name="area"/> (page space) is in view; nothing moves if it already is.</summary>
    void Reveal(int page, Rect area);

    void ShowFind();

    void ShowGoToPage();

    // ----- Pages in the window

    /// <summary>The pages that meet the window, in order. For a tool that builds its overlays on demand.</summary>
    IReadOnlyList<int> VisiblePages { get; }

    /// <summary>The page size in points as shown before the viewer's rotation.</summary>
    Size PageSize(int page);

    /// <summary>
    /// Takes page space of <paramref name="page"/> to <see cref="View"/>'s coordinates at the present scroll, zoom and
    /// rotation. Null for a page the viewer has not laid out (the other pages of a one-page-at-a-time view). It is
    /// stale after the next <see cref="ViewChanged"/>.
    /// </summary>
    Matrix? PageToView(int page);

    /// <summary>
    /// The page under a point of <see cref="View"/> and the point in its page space; null between pages, or over the
    /// viewer's own bar. With <paramref name="nearest"/> the closest page is taken instead of null.
    /// </summary>
    PagePoint? ViewToPage(Point view, bool nearest = false);

    /// <summary>
    /// The engine's geometry of a page (crop box, /Rotate): <c>ToUser</c> turns a point of page space into PDF user
    /// space. Valid until the file next changes.
    /// </summary>
    PageGeometry Geometry(int page);

    /// <summary>The layer a tool draws on for a page; made on first use and kept for as long as the document is shown. See <see cref="PageOverlay"/>.</summary>
    PageOverlay Overlay(int page);

    /// <summary>Raised when the scroll position, zoom, rotation or arrangement changed: <see cref="PageToView"/> answers differently.</summary>
    event EventHandler? ViewChanged;

    /// <summary>Raised when <see cref="PageIndex"/> changed, by scrolling or by going to a page.</summary>
    event EventHandler? PageChanged;

    // ----- The pointer

    /// <summary>What dragging does. Setting it (the Hand and Select buttons do) also drops any <see cref="PointerTool"/>.</summary>
    PointerMode Mode { get; set; }

    /// <summary>Raised when <see cref="Mode"/> was set.</summary>
    event EventHandler? ModeChanged;

    /// <summary>Takes the left button on the pages from the viewer. Null gives it back; setting another cancels the one before.</summary>
    IPagePointerTool? PointerTool { get; set; }

    // ----- Text

    /// <summary>The characters of a page and their places in PDF user space, for this revision of the file; null when the text cannot be read.</summary>
    Task<TextPage?> GetTextAsync(int page);

    bool HasSelection { get; }

    /// <summary>The selected text, page by page.</summary>
    Task<IReadOnlyList<SelectedRun>> GetSelectionAsync();

    void SelectAll();

    void ClearSelection();

    /// <summary>Raised when the selection changed or was cleared.</summary>
    event EventHandler? SelectionChanged;

    /// <summary>The search the find bar and the Search panel share.</summary>
    ViewerSearch Search { get; }

    // ----- Layers

    /// <summary>
    /// Shows or hides a layer in the view only. The viewer draws a copy of the file with the layer changed, so the file
    /// and its undo history stay as they are; the override is dropped when the file is closed.
    /// </summary>
    void SetLayerVisible(PdfReference layer, bool visible);

    /// <summary>The layers as the view shows them: the file's, with what <see cref="SetLayerVisible"/> changed.</summary>
    LayerSet Layers { get; }

    /// <summary>Raised when <see cref="Layers"/> answers differently: after a toggle, and when the file changed.</summary>
    event EventHandler? LayersChanged;
}
