import Foundation

// Twin of windows/LazyPDF.Core/Office/Pptx/PptxModel.cs.

/// What a presentation may hold. Too many slides, too many shapes drawn in all or too much text in all is refused; the rest is cut and noted.
struct PptxLimits {
    var maxSlides = 1000
    var maxShapes = 5000
    var maxParagraphs = 5000
    var maxTextLength = 100_000
    var maxTotalText = 4_000_000
    var maxDrawnShapes = 200_000
    var maxGroupDepth = 5
    var maxPictures = 2000
    var maxTableRows = 500
    var maxTableColumns = 64

    static let minSide = 36.0
    static let maxSide = 14_400.0
    static let standard = PptxLimits()
}

enum PptxSkipped {
    static let hiddenSlide = "hidden-slide"
    static let shape = "slide-shape"
    static let gradient = "slide-gradient"
    static let textCut = "slide-text-cut"
    static let textRotation = "text-rotation"
    static let customGeometry = "slide-custom-geometry"
    static let effect = "slide-effect"
    static let chart = "slide-chart"
    static let smartArt = "slide-smartart"
    static let media = "slide-media"
    static let embeddedObject = "slide-object"
    static let tableStyle = "slide-table-style"
}

/// What fills the page behind a slide: a color, a picture stretched over it, or nothing.
struct PptxBackground {
    let color: Int?
    let picture: LayoutPicture?
}

/// The text of a shape: the room inside it and its paragraphs, already resolved against the master, layout and autofit.
struct PptxBody {
    var left = 0.0
    var top = 0.0
    var right = 0.0
    var bottom = 0.0
    var anchor = LayoutVAlign.top
    var wrap = true
    var paragraphs: [LayoutParagraph] = []
}

/// A table with its top left corner at x, y in points; the column widths and the minimum row heights are those of the file.
struct PptxTable {
    let x: Double
    let y: Double
    let table: LayoutTable
}

/// A shape in points from the top left of the slide. A slide number field in the text is a `LayoutField.pageNumber` run.
/// The frame is where the text goes, turned back upright. `fill` is a plain rectangle of the frame; any other outline, with its
/// arrowheads, is in `paths`, already placed on the slide.
struct PptxShape {
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    var fill: Int?
    var paths: [PlacedPath] = []
    var picture: PlacedImage?
    var table: PptxTable?
    var body: PptxBody?
}

struct PptxSlide {
    var number = 0
    var background: PptxBackground?
    /// Bottom to top: the master's shapes, the layout's, then the slide's own.
    var shapes: [PptxShape] = []
}

struct PptxPresentation {
    var width = 0.0
    var height = 0.0
    var slides: [PptxSlide] = []
    var skipped: [SkippedFeature] = []
}
