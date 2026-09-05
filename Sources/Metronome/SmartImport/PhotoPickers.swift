#if canImport(UIKit)
import SwiftUI
import PhotosUI
import UIKit

/// The outcome of a photo pick, modelled explicitly so the presenting view can react deterministically:
/// dismiss on *any* outcome, start OCR only on `.picked`, and show a **visible** error on `.failed` — a
/// failure is never silent.
enum ImagePickResult {
    case picked(UIImage)
    case cancelled
    case failed
}

/// SwiftUI wrapper over `PHPickerViewController` for picking a single image from the photo library.
/// PHPicker runs out-of-process, so it needs no photo-library permission and returns only the chosen image.
///
/// The result is delivered via `onFinish` **on the main queue**, and the *caller* owns dismissal (it sets
/// the presenting binding false). The picker deliberately does **not** use `@Environment(\.dismiss)`:
/// captured into a `UIViewControllerRepresentable`/coordinator it is unreliable and can be a no-op, which
/// leaves the picker on screen after a selection so the review screen never surfaces — the "photo import
/// does nothing" symptom.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onFinish: (ImagePickResult) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish   // keep the latest closure if the parent re-renders
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onFinish: (ImagePickResult) -> Void
        private var didFinish = false
        init(onFinish: @escaping (ImagePickResult) -> Void) { self.onFinish = onFinish }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // No selection → the user tapped Cancel. Dismiss without starting OCR.
            guard let provider = results.first?.itemProvider else { finish(.cancelled); return }
            guard provider.canLoadObject(ofClass: UIImage.self) else { finish(.failed); return }
            // loadObject calls back on a private queue — hop to main for the UI update + OCR kickoff. A
            // strong `self` capture (the closure is owned by the load op, not by us — no cycle) guarantees
            // the outcome is delivered even if the sheet is mid-dismiss.
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async {
                    if let image = object as? UIImage { self.finish(.picked(image)) }
                    else { self.finish(.failed) }
                }
            }
        }

        /// Deliver exactly one outcome (guards against a late/duplicate callback).
        private func finish(_ result: ImagePickResult) {
            guard !didFinish else { return }
            didFinish = true
            onFinish(result)
        }
    }
}

/// SwiftUI wrapper over `UIImagePickerController` in camera mode. Requires `NSCameraUsageDescription`
/// (declared in `project.yml`); `UIImagePickerController` requests camera authorization itself on first
/// present. Offered only when `isAvailable` (false on Simulator). The caller owns dismissal (same rationale
/// as `PhotoLibraryPicker` — no `@Environment(\.dismiss)`).
struct CameraPicker: UIViewControllerRepresentable {
    var onFinish: (ImagePickResult) -> Void

    /// Whether this device actually has a usable camera. False on the Simulator, so the UI hides the
    /// camera entry there rather than presenting a controller that can't capture anything.
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    /// `UIImagePickerController`'s delegate is Obj-C and also requires `UINavigationControllerDelegate`.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onFinish: (ImagePickResult) -> Void
        private var didFinish = false
        init(onFinish: @escaping (ImagePickResult) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { finish(.picked(image)) }
            else { finish(.failed) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            finish(.cancelled)
        }

        private func finish(_ result: ImagePickResult) {
            guard !didFinish else { return }
            didFinish = true
            onFinish(result)
        }
    }
}
#endif
