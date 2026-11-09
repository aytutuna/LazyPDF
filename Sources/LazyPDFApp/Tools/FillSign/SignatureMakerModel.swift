import Foundation
import Observation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/FillSign/SignatureMaker.xaml.cs: makes a signature or initials by typing, drawing or choosing a
// picture, and keeps the image made. The sheet that shows it is in LazyPDFUI.

/// What the signature maker asks of the system: handwriting faces to type a name in, the typed name drawn as an image, and the
/// orientation a camera stored in a picture file.
@MainActor
public protocol SignatureSystem: AnyObject {
    /// Handwriting faces the system has, in the order they are offered; never empty.
    var faces: [String] { get }

    func typed(_ text: String, face: String) -> PdfRgbaImage?

    /// EXIF orientation, 1 to 8; 1 when the file says none.
    func orientation(of file: [UInt8]) -> Int
}

@MainActor
@Observable
public final class SignatureMakerModel {
    public enum Mode {
        case type, draw, picture
    }

    public private(set) var mode = Mode.type
    public private(set) var name = ""
    public private(set) var faceIndex = 0
    public private(set) var strokes = SignatureStrokes()

    /// The image made so far; nil until there is something to use.
    public private(set) var image: PdfRgbaImage?
    public private(set) var pictureNote = ""
    public private(set) var canTurn = false

    /// Kept for next time.
    public var keep = true

    @ObservationIgnored private var picture: PdfRgbaImage?
    @ObservationIgnored private let system: SignatureSystem
    @ObservationIgnored private let codec: ImageCodec

    public init(system: SignatureSystem, codec: ImageCodec) {
        self.system = system
        self.codec = codec
        reset()
    }

    public var faces: [String] { system.faces }

    /// Starts over with an empty page.
    public func reset() {
        name = ""
        strokes.clear()
        picture = nil
        canTurn = false
        pictureNote = L10n.t("Sign on white paper and take a photo. The paper is made see-through.")
        mode = .type
        rebuild()
    }

    public func setMode(_ mode: Mode) {
        self.mode = mode
        rebuild()
    }

    public func setName(_ name: String) {
        self.name = name
        rebuild()
    }

    public func setFace(_ index: Int) {
        faceIndex = index
        rebuild()
    }

    // MARK: Ink

    public func beginStroke(_ point: ViewPoint) {
        strokes.begin(point)
    }

    public func extendStroke(_ point: ViewPoint) {
        strokes.extend(point)
    }

    /// The image is made when a stroke ends, not at every point of it.
    public func endStroke() {
        rebuild()
    }

    public func undoStroke() {
        strokes.removeLast()
        rebuild()
    }

    public func clearInk() {
        strokes.clear()
        rebuild()
    }

    // MARK: Picture

    /// Asks for a picture and makes the signature from it: the paper goes clear and the ink stays.
    public func choosePicture(using picker: ToolFilePicker) async {
        guard let file = await picker.pickFiles([.picture], multiple: false).first else { return }
        defer { file.access?.stop() }
        if let data = try? Data(contentsOf: file.url) {
            let bytes = [UInt8](data)
            picture = SignatureArt.fromFile(bytes, codec, orientation: system.orientation(of: bytes))
        } else {
            picture = nil
        }
        canTurn = picture != nil
        pictureNote = picture == nil ? L10n.t("That file is not a picture Lazy PDF can read. Choose a PNG or JPEG.") : file.url.lastPathComponent
        rebuild()
    }

    public func turnPicture() {
        guard let picture else { return }
        self.picture = SignatureArt.turn(picture)
        rebuild()
    }

    private func rebuild() {
        switch mode {
        case .type:
            let face = system.faces.indices.contains(faceIndex) ? system.faces[faceIndex] : system.faces.first ?? ""
            image = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : system.typed(name, face: face)
        case .draw:
            image = SignatureArt.drawn(strokes)
        case .picture:
            image = picture
        }
    }
}
