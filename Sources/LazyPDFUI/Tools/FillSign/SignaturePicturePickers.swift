#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import LazyPDFKit
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import VisionKit

// The ways an iPhone or iPad gets a signature picture besides the file picker. Each hands back JPEG bytes (the camera's
// orientation travels in them) and a name for the note under the buttons.

struct PictureBytes {
    let bytes: [UInt8]
    let name: String
}

/// The photo library, through the system picker, which needs no permission.
struct PhotosChooser: UIViewControllerRepresentable {
    let done: (PictureBytes?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let done: (PictureBytes?) -> Void

        init(_ done: @escaping (PictureBytes?) -> Void) { self.done = done }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { return done(nil) }
            let done = done
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                let picture = data.map { PictureBytes(bytes: [UInt8]($0), name: provider.suggestedName ?? "") }
                DispatchQueue.main.async { done(picture) }
            }
        }
    }
}

/// The camera, for one photo of a signed sheet.
struct CameraChooser: UIViewControllerRepresentable {
    let done: (PictureBytes?) -> Void

    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (PictureBytes?) -> Void

        init(_ done: @escaping (PictureBytes?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            done(image?.jpegData(compressionQuality: 0.9).map { PictureBytes(bytes: [UInt8]($0), name: L10n.t("Take a photo")) })
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

/// The document scanner, which finds the paper's edges and flattens it; the first page is used.
struct PaperScanner: UIViewControllerRepresentable {
    let done: (PictureBytes?) -> Void

    static var available: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: (PictureBytes?) -> Void

        init(_ done: @escaping (PictureBytes?) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let image = scan.pageCount > 0 ? scan.imageOfPage(at: 0) : nil
            done(image?.jpegData(compressionQuality: 0.9).map { PictureBytes(bytes: [UInt8]($0), name: L10n.t("Scan the paper")) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done(nil) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { done(nil) }
    }
}
#endif
