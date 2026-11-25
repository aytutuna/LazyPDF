import Foundation

// Twin of windows/LazyPDF.Core/Editing/PageEditor.cs: changes what is already on one page: its text, images and paths.
// Each public change is one `PdfEditSession.commit`, so one undo step. The editor reads the page when asked and again
// after each change; objects and ranges handed out earlier are stale after a change. Everything is in user space.
// What the C# raises as an exception from a file (PdfReadException, from adding an object) is thrown here too, so the
// changing members are `throws`. The member `text` is the C# Text, `fileExtension` the C# Extension.

/// The outcome of a change to text. `done`: the change was made and committed. `substitutions`: fonts that stood in
/// for the one in the file. `grew`: a paragraph took more lines than it had; the blocks below it stayed where they
/// were. `overlaps`: new text runs into text that follows it on the line, or off the page. `problem`: why nothing was
/// done, when `done` is false.
public struct TextEditResult {
    public let done: Bool
    public let substitutions: [FontSubstitution]
    public let grew: Bool
    public var overlaps: Bool
    public let problem: String?

    init(_ done: Bool, _ substitutions: [FontSubstitution], _ grew: Bool, _ overlaps: Bool, _ problem: String?) {
        self.done = done
        self.substitutions = substitutions
        self.grew = grew
        self.overlaps = overlaps
        self.problem = problem
    }

    static func failed(_ problem: String) -> TextEditResult { TextEditResult(false, [], false, false, problem) }
}

/// The outcome of a change to objects: how many were changed and which were left alone.
public struct ObjectEditResult {
    public let changed: Int
    public let skipped: [SkippedObject]

    init(_ changed: Int, _ skipped: [SkippedObject]) {
        self.changed = changed
        self.skipped = skipped
    }

    public var done: Bool { changed > 0 }
}

/// An object that could not be changed, and why.
public struct SkippedObject: Equatable {
    public let id: Int
    public let reason: String

    public init(id: Int, reason: String) {
        self.id = id
        self.reason = reason
    }
}

public final class PageEditor {
    private let session: PdfEditSession
    let fonts: FontSource?
    let codec: ImageCodec?
    private var loaded: PageModel?
    private var loadedDocument: PdfDocument?

    public init(_ session: PdfEditSession, _ pageIndex: Int, _ fonts: FontSource? = nil, _ images: ImageCodec? = nil) throws {
        if pageIndex < 0 || pageIndex >= session.document.pages.count { throw ArgumentException("pageIndex") }
        self.session = session
        self.pageIndex = pageIndex
        self.fonts = fonts
        codec = images
    }

    public let pageIndex: Int

    /// The text, images and paths of the page in the order they are painted.
    public var objects: [PageObject] { get throws { try model.objects } }

    /// The page's text as laid out, whose `TextRange`s the text changes take.
    public var text: TextPage { get throws { try model.text } }

    /// Forgets what was read; the next member reads the page again.
    public func refresh() { loaded = nil }

    var model: PageModel {
        get throws {
            // A commit, undo or redo anywhere gives the session a new document, which can have fewer pages.
            if let loaded, loadedDocument === session.document { return loaded }
            let document = session.document
            if pageIndex >= document.pages.count { throw ArgumentException("pageIndex") }
            let created = PageModel.load(document, pageIndex)
            loadedDocument = document
            loaded = created
            return created
        }
    }

    /// Commits what the batch holds as one step and forgets the model.
    @discardableResult
    func commit(_ label: String) throws -> Bool {
        let done = try session.commit(label)
        loaded = nil
        return done
    }

    /// The topmost object under the point, `tolerance` user space units wide.
    public func hitTest(_ x: Double, _ y: Double, _ tolerance: Double = 1) throws -> PageObject? {
        let objects = try model.objects
        var i = objects.count - 1
        while i >= 0 {
            if hits(objects[i], x, y, tolerance) { return objects[i] }
            i -= 1
        }
        return nil
    }

    /// The objects whose bounds touch the rectangle, or lie wholly inside it.
    public func select(_ rect: PdfRect, _ contained: Bool = false) throws -> [PageObject] {
        try model.objects.filter { o in
            contained
                ? o.bounds.left >= rect.left && o.bounds.right <= rect.right && o.bounds.bottom >= rect.bottom && o.bounds.top <= rect.top
                : o.bounds.left <= rect.right && o.bounds.right >= rect.left && o.bounds.bottom <= rect.top && o.bounds.top >= rect.bottom
        }
    }

    private func hits(_ o: PageObject, _ x: Double, _ y: Double, _ tolerance: Double) -> Bool {
        let b = o.bounds
        if x < b.left - tolerance || x > b.right + tolerance || y < b.bottom - tolerance || y > b.top + tolerance { return false }
        switch o {
        case let text as TextObject:
            return text.glyphs.contains { $0.quad.distanceTo(x, y) <= tolerance }
        case let image as ImageObject:
            guard let inverse = image.placement.invert() else { return true }
            let (u, v) = inverse.transform(x, y)
            let slack = tolerance / Swift.max(image.placement.scaleFactor, 1e-9)
            return u >= -slack && u <= 1 + slack && v >= -slack && v <= 1 + slack
        case let path as PathObject:
            return PathHit.contains(path, x, y, tolerance)
        default:
            return true
        }
    }

    // Applies the batch, commits it as one step and forgets the model; a change that cannot be made is reported, not thrown.
    func finish(_ label: String, _ batch: EditBatch, _ builder: TextBuilder, _ editor: TextEditor? = nil) throws -> TextEditResult {
        do {
            try batch.apply()
            builder.writeAdditions()
        } catch let e as EditConflictException {
            batch.discard()
            return .failed(e.message)
        }
        let done = try commit(label)
        return TextEditResult(done, builder.substitutions, editor?.grew ?? false, editor?.overlaps ?? false, done ? nil : EditingText.nothingChanged)
    }

    func editText(_ label: String, _ change: (TextEditor) throws -> Void) throws -> TextEditResult {
        let model = try self.model
        let batch = EditBatch(model.document, model.page, model.scan)
        let builder = TextBuilder(model.document, batch, fonts)
        let editor = TextEditor(model, batch, builder, fonts)
        do {
            try change(editor)
        } catch let e as EditConflictException {
            batch.discard()
            return .failed(e.message)
        }
        return try finish(label, batch, builder, editor)
    }
}

/// Whether a point is on a path: inside its fill, or within reach of its stroke.
enum PathHit {
    static func contains(_ path: PathObject, _ x: Double, _ y: Double, _ tolerance: Double) -> Bool {
        var edges: [(x1: Double, y1: Double, x2: Double, y2: Double)] = []
        var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
        for s in path.segments {
            switch s.kind {
            case .move:
                if cx != sx || cy != sy { edges.append((cx, cy, sx, sy)) }
                (cx, cy, sx, sy) = (s.x1, s.y1, s.x1, s.y1)
            case .line:
                edges.append((cx, cy, s.x1, s.y1))
                (cx, cy) = (s.x1, s.y1)
            case .curve:
                var px = cx, py = cy
                for i in 1...8 {
                    let t = Double(i) / 8.0, u = 1 - t
                    let qx = u * u * u * cx + 3 * u * u * t * s.x1 + 3 * u * t * t * s.x2 + t * t * t * s.x3
                    let qy = u * u * u * cy + 3 * u * u * t * s.y1 + 3 * u * t * t * s.y2 + t * t * t * s.y3
                    edges.append((px, py, qx, qy))
                    (px, py) = (qx, qy)
                }
                (cx, cy) = (s.x3, s.y3)
            case .close:
                edges.append((cx, cy, sx, sy))
                (cx, cy) = (sx, sy)
            }
        }
        if cx != sx || cy != sy { edges.append((cx, cy, sx, sy)) }
        let reach = tolerance + (path.stroke ? path.lineWidth / 2 : 0)
        if path.stroke || !path.fill {
            for e in edges where distance(e, x, y) <= reach { return true }
        }
        if !path.fill { return false }
        var winding = 0, crossings = 0
        for e in edges {
            if (e.y1 <= y) == (e.y2 <= y) { continue }
            let at = e.x1 + (y - e.y1) / (e.y2 - e.y1) * (e.x2 - e.x1)
            if at > x { continue }
            crossings += 1
            winding += e.y2 > e.y1 ? 1 : -1
        }
        return path.evenOdd ? crossings % 2 == 1 : winding != 0
    }

    private static func distance(_ e: (x1: Double, y1: Double, x2: Double, y2: Double), _ x: Double, _ y: Double) -> Double {
        let dx = e.x2 - e.x1, dy = e.y2 - e.y1
        let length2 = dx * dx + dy * dy
        let t = length2 < 1e-12 ? 0 : Swift.min(Swift.max(((x - e.x1) * dx + (y - e.y1) * dy) / length2, 0), 1)
        return (pow(x - (e.x1 + t * dx), 2) + pow(y - (e.y1 + t * dy), 2)).squareRoot()
    }
}
