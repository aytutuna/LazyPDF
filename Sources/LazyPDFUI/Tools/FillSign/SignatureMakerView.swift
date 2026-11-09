#if canImport(SwiftUI) && canImport(CoreGraphics)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The sheet that makes a signature or initials; follows windows/LazyPDF.App/Tools/FillSign/SignatureMaker.xaml. The ink and the image
// made live in SignatureMakerModel; this draws them and passes the pen on.

struct SignatureMakerView: View {
    let model: FillSignModel
    var maker: SignatureMakerModel { model.maker }

    var body: some View {
        ToolForm {
            Picker(L10n.t("Make a new one"), selection: Binding(get: { maker.mode }, set: { maker.setMode($0) })) {
                Text(L10n.t("Type")).tag(SignatureMakerModel.Mode.type)
                Text(L10n.t("Draw")).tag(SignatureMakerModel.Mode.draw)
                Text(L10n.t("Picture")).tag(SignatureMakerModel.Mode.picture)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch maker.mode {
            case .type: typePane
            case .draw: drawPane
            case .picture: picturePane
            }

            FieldLabel(L10n.t("Preview"))
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                if let image = maker.image { SignaturePicture(image: image).padding(6) }
            }
            .frame(height: 96)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("Preview"))

            Toggle(L10n.t("Keep for next time"), isOn: Binding(get: { maker.keep }, set: { maker.keep = $0 }))
            HStack {
                Button {
                    model.useMade()
                } label: {
                    Label(L10n.t("Use"), systemImage: "checkmark").frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(maker.image == nil)
                Button(L10n.t("Cancel")) { model.cancelMaker() }
                    .frame(minHeight: 44)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var typePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabelledField(L10n.t("Name")) {
                TextField(L10n.t("Name"), text: Binding(get: { maker.name }, set: { maker.setName($0) }))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            LabelledField(L10n.t("Style")) {
                Picker(L10n.t("Style"), selection: Binding(get: { maker.faceIndex }, set: { maker.setFace($0) })) {
                    ForEach(Array(maker.faces.enumerated()), id: \.offset) {
                        Text($0.element).font(.custom($0.element, size: 18)).tag($0.offset)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var drawPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            SignaturePad(maker: maker)
                .frame(height: 140)
            HStack {
                Button {
                    maker.undoStroke()
                } label: {
                    Label(L10n.t("Undo stroke"), systemImage: "arrow.uturn.backward").frame(minHeight: 44)
                }
                .disabled(maker.strokes.isEmpty)
                Button {
                    maker.clearInk()
                } label: {
                    Label(L10n.t("Clear"), systemImage: "eraser").frame(minHeight: 44)
                }
                .disabled(maker.strokes.isEmpty)
            }
        }
    }

    private var picturePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await model.chooseMakerPicture() }
                } label: {
                    Label(L10n.t("Choose a picture"), systemImage: "photo").frame(minHeight: 44)
                }
                Button {
                    maker.turnPicture()
                } label: {
                    Label(L10n.t("Turn"), systemImage: "rotate.right").frame(minHeight: 44)
                }
                .disabled(!maker.canTurn)
                .accessibilityLabel(L10n.t("Turn the picture a quarter"))
            }
            ReasonText(maker.pictureNote)
        }
    }
}

/// The area a signature is drawn in with a finger, a Pencil or a mouse. Each stroke goes to the model a point at a time.
struct SignaturePad: View {
    let maker: SignatureMakerModel
    @State private var drawing = false

    var body: some View {
        // Read here, not in the drawing closure, so the view follows the strokes.
        let strokes = maker.strokes.strokes
        return Canvas { context, _ in
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                var path = Path()
                path.move(to: CGPoint(x: first.x, y: first.y))
                if stroke.count == 1 { path.addLine(to: CGPoint(x: first.x, y: first.y)) }
                for point in stroke.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: SignatureStrokes.penWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.5)))
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let point = ViewPoint(Double(value.location.x), Double(value.location.y))
            if drawing {
                maker.extendStroke(point)
            } else {
                drawing = true
                maker.beginStroke(point)
            }
        }.onEnded { value in
            maker.extendStroke(ViewPoint(Double(value.location.x), Double(value.location.y)))
            drawing = false
            maker.endStroke()
        })
        .accessibilityElement()
        .accessibilityLabel(L10n.t("Drawing area for the signature"))
    }
}
#endif
