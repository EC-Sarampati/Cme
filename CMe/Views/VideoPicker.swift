import SwiftUI
import PhotosUI
import AVFoundation

struct VideoPicker: UIViewControllerRepresentable {
    @Binding var showPicker: Bool
    @Binding var videoURL: URL?
    @ObservedObject var viewModel: VideoProcessingViewModel
    var selectedAudio: String

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker
        init(_ parent: VideoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let item = results.first else {
                print("No video selected")
                return
            }

            print("Picker triggered on iPad/iPhone")

            // Start compression indicator
            DispatchQueue.main.async {
                self.parent.viewModel.isCompressingVideo = true
            }

            item.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.movie") { url, error in
                if let error = error {
                    print("Picker load error:", error.localizedDescription)
                    DispatchQueue.main.async {
                        self.parent.viewModel.isCompressingVideo = false
                    }
                    return
                }

                guard let url = url else {
                    print("No video URL from provider")
                    DispatchQueue.main.async {
                        self.parent.viewModel.isCompressingVideo = false
                    }
                    return
                }

                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: temp)
                try? FileManager.default.copyItem(at: url, to: temp)

                print("Copied video:", temp.lastPathComponent)

                compressVideo(inputURL: temp) { compressedURL in
                    DispatchQueue.main.async {
                        self.parent.viewModel.isCompressingVideo = false
                        self.parent.showPicker = false

                        let finalURL = compressedURL ?? temp
                        self.parent.videoURL = finalURL
                        print("Compressed video ready:", finalURL.lastPathComponent)

                        let command = self.parent.selectedAudio
                        print("Using audio command:", command)

                        // 🔴 FIX: correct labels + no await (processFullVideo is not async)
                        // Also pass finalURL (compressed) instead of the original url
                        Task { @MainActor in
                            print("Starting processing task...")
                            await self.parent.viewModel.processFullVideoPythonStyle(inputURL: finalURL)
                            print("Processing task started successfully.")
                        }
                    }
                }
            }
        }
    }
}

func compressVideo(inputURL: URL, completion: @escaping (URL?) -> Void) {
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("compressed_\(UUID().uuidString).mp4")

    let asset = AVAsset(url: inputURL)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
        print("Failed to create export session.")
        completion(nil)
        return
    }

    export.outputURL = outputURL
    export.outputFileType = .mp4

    export.exportAsynchronously {
        switch export.status {
        case .completed:
            print("Compressed video saved at:", outputURL.path)
            completion(outputURL)
        case .failed:
            print("Compression failed:", export.error?.localizedDescription ?? "Unknown error")
            completion(nil)
        case .cancelled:
            print("Compression cancelled.")
            completion(nil)
        default:
            break
        }
    }
}
